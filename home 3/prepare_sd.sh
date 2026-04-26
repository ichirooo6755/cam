#!/bin/bash
# Raspberry Pi Zero 2W SDカードセットアップスクリプト
# Raspberry Pi Imagerで書き込み完了後に実行する
set -e

BOOT="/Volumes/bootfs"
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== PiCamera SD カードセットアップ ==="

# bootパーティション確認
if [ ! -d "$BOOT" ]; then
    echo "エラー: $BOOT が見つかりません"
    echo "Raspberry Pi Imagerでの書き込みが完了しているか確認してください"
    exit 1
fi

if [ ! -f "$BOOT/cmdline.txt" ]; then
    echo "エラー: bootパーティションが正しくマウントされていません"
    exit 1
fi

echo "[1/4] ペイロードをbootパーティションにコピー中..."
mkdir -p "$BOOT/picamera_payload"
cp "$SRC/api_server.py"           "$BOOT/picamera_payload/"
cp "$SRC/camera_service.py"       "$BOOT/picamera_payload/"
cp "$SRC/wifi_manager.py"         "$BOOT/picamera_payload/"
cp "$SRC/metering_calibrate.py"   "$BOOT/picamera_payload/"
cp "$SRC/api-server.service"      "$BOOT/picamera_payload/"
cp "$SRC/camera-service.service"  "$BOOT/picamera_payload/"
cp "$SRC/camera_settings.json"    "$BOOT/picamera_payload/"
echo "   コピー完了: $(ls "$BOOT/picamera_payload/" | wc -l | tr -d ' ') ファイル"

echo "[2/4] firstrun.sh にデプロイ処理を追記中..."

# Imagerが生成したfirstrun.shの末尾に挿入
# "exit 0" の直前にブロックを追記
FIRSTRUN="$BOOT/firstrun.sh"

if [ ! -f "$FIRSTRUN" ]; then
    echo "エラー: firstrun.sh が見つかりません"
    echo "Raspberry Pi ImagerのOS設定でSSH/ユーザーを設定したか確認してください"
    exit 1
fi

# 既に追記済みか確認
if grep -q "picamera_payload" "$FIRSTRUN"; then
    echo "   firstrun.sh にはすでにPiCameraブロックが含まれています（スキップ）"
else
    # exit 0 の直前に追記
    PICAMERA_BLOCK='
###############################################
# PiCamera payload deployment
###############################################
# 必要パッケージのインストール（Lite/Desktop 両対応、冪等）
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y --no-install-recommends \
    python3-picamera2 python3-libcamera python3-pil \
    rpicam-apps \
    2>/dev/null || true

# NetworkManager 有効化（nmcli でホットスポットを制御するため）
systemctl enable NetworkManager 2>/dev/null || true

cp /boot/firmware/picamera_payload/api_server.py /home/pi/
cp /boot/firmware/picamera_payload/camera_service.py /home/pi/
cp /boot/firmware/picamera_payload/wifi_manager.py /home/pi/
cp /boot/firmware/picamera_payload/metering_calibrate.py /home/pi/
cp /boot/firmware/picamera_payload/camera_settings.json /home/pi/
chown pi:pi /home/pi/*.py /home/pi/camera_settings.json

mkdir -p /home/pi/photos
chown pi:pi /home/pi/photos

cp /boot/firmware/picamera_payload/camera-service.service /etc/systemd/system/
cp /boot/firmware/picamera_payload/api-server.service /etc/systemd/system/
systemctl daemon-reload
systemctl enable camera-service api-server

# wifi_mode=ap を強制設定（APとして起動させる）
python3 -c "
import json
with open(\"/home/pi/camera_settings.json\") as f:
    s = json.load(f)
s[\"wifi_mode\"] = \"ap\"
with open(\"/home/pi/camera_settings.json\", \"w\") as f:
    json.dump(s, f, indent=2)
"
chown pi:pi /home/pi/camera_settings.json

# passwordless sudo 確認（Imagerが作成済みのはずだが念のため）
if [ ! -f /etc/sudoers.d/010_pi-nopasswd ]; then
    echo "pi ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/010_pi-nopasswd
    chmod 0440 /etc/sudoers.d/010_pi-nopasswd
fi

# Wi-Fi 規制ドメイン（日本）
raspi-config nonint do_wifi_country JP 2>/dev/null || true

# IMX477 オーバーレイ（camera_auto_detect=1 でも明示追加で確実に認識）
grep -q "dtoverlay=imx477" /boot/firmware/config.txt || echo "dtoverlay=imx477" >> /boot/firmware/config.txt
# camera_auto_detect は imx477 と競合するため無効化
sed -i "s/^camera_auto_detect=1/camera_auto_detect=0/" /boot/firmware/config.txt

# ペイロードを削除
rm -rf /boot/firmware/picamera_payload
'

    # exit 0 の前に挿入
    python3 - <<PYEOF
content = open("$FIRSTRUN").read()
block = '''$PICAMERA_BLOCK'''
if "exit 0" in content:
    content = content.replace("exit 0", block + "\nexit 0", 1)
else:
    content = content.rstrip() + "\n" + block + "\nexit 0\n"
open("$FIRSTRUN", "w").write(content)
PYEOF

    echo "   firstrun.sh に追記完了"
fi

echo "[3/4] cmdline.txt を確認中..."
if grep -q "systemd.run=" "$BOOT/cmdline.txt"; then
    echo "   OK: firstrunフック確認済み"
    grep "systemd.run=" "$BOOT/cmdline.txt" | sed 's/.*\(systemd.run=[^ ]*\).*/   → \1/'
else
    echo "   警告: systemd.run が cmdline.txt に見つかりません"
    echo "   Imagerの設定（SSH/ユーザー設定）が有効になっているか確認してください"
fi

echo "[4/4] SDカードを安全に取り出し中..."
# disk番号を動的取得
BOOT_DISK=$(diskutil list | awk '/bootfs/{print $NF}' | sed 's/s[0-9]*$//' | head -1)
if [ -n "$BOOT_DISK" ]; then
    diskutil unmountDisk "$BOOT_DISK"
    echo "   取り出し完了 ($BOOT_DISK)"
else
    echo "   警告: bootfsのdisk番号を自動取得できませんでした"
    echo "   手動で取り出してください"
fi

echo ""
echo "=== セットアップ完了 ==="
echo ""
echo "次のステップ:"
echo "  1. SDカードをRaspberry Pi Zero 2Wに挿入"
echo "  2. 電源を入れる（初回起動に5〜10分かかります ※apt install実行のため）"
echo "  3. 家庭Wi-Fiに一旦接続してapt完了を待つ"
echo "  4. 再起動後、Wi-Fiに 'PiCamera' が現れる"
echo "  5. パスワード: picamera123 で接続"
echo "  6. 動作確認: curl http://192.168.4.1:8001/api/status"
echo ""
