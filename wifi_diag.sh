#!/bin/bash
# PiCamera WiFiに接続 → 診断コマンド実行 → Aaa に戻るスクリプト
set -e

PICAM_SSID="PiCamera"
PICAM_PASS="picamera123"
RETURN_SSID="AaaのiPhone"
PI_HOST="192.168.4.1"
DIAG_FILE="/Users/sugawaraichirou/Documents/アプリ/diag_output.txt"

echo "=== PiCamera 診断スクリプト ===" | tee "$DIAG_FILE"
echo "開始: $(date)" | tee -a "$DIAG_FILE"

# 1. PiCamera WiFiに接続
echo ">>> PiCamera WiFiに接続中..." | tee -a "$DIAG_FILE"
networksetup -setairportnetwork en0 "$PICAM_SSID" "$PICAM_PASS" 2>&1 | tee -a "$DIAG_FILE"
sleep 5

# 接続確認
echo ">>> 接続確認..." | tee -a "$DIAG_FILE"
if ! ping -c 2 -W 3 "$PI_HOST" >> "$DIAG_FILE" 2>&1; then
    echo "ERROR: PiCamera に到達できません。Aaa に戻ります。" | tee -a "$DIAG_FILE"
    networksetup -setairportnetwork en0 "$RETURN_SSID" 2>&1 || true
    exit 1
fi

# 2. 診断コマンド実行
echo "" >> "$DIAG_FILE"
echo "=== 有効な設定 ===" | tee -a "$DIAG_FILE"
curl -s "http://$PI_HOST:8001/api/settings" 2>&1 | python3 -m json.tool >> "$DIAG_FILE" 2>&1

echo "" >> "$DIAG_FILE"
echo "=== センサー状態 ===" | tee -a "$DIAG_FILE"
curl -s "http://$PI_HOST:8001/api/sensor/status" 2>&1 | python3 -m json.tool >> "$DIAG_FILE" 2>&1

echo "" >> "$DIAG_FILE"
echo "=== camera-service ログ (最新50行) ===" | tee -a "$DIAG_FILE"
ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new "pi@$PI_HOST" \
    "journalctl -u camera-service --no-pager -n 50" >> "$DIAG_FILE" 2>&1

echo "" >> "$DIAG_FILE"
echo "=== api-server ログ (最新30行) ===" | tee -a "$DIAG_FILE"
ssh -o ConnectTimeout=10 "pi@$PI_HOST" \
    "journalctl -u api-server --no-pager -n 30" >> "$DIAG_FILE" 2>&1

echo "" >> "$DIAG_FILE"
echo "=== サービス再起動時刻 ===" | tee -a "$DIAG_FILE"
ssh -o ConnectTimeout=10 "pi@$PI_HOST" \
    "systemctl show camera-service -p ActiveEnterTimestamp; systemctl show api-server -p ActiveEnterTimestamp" >> "$DIAG_FILE" 2>&1

echo "" >> "$DIAG_FILE"
echo "=== session_overrides 確認 ===" | tee -a "$DIAG_FILE"
ssh -o ConnectTimeout=10 "pi@$PI_HOST" \
    "cat /home/pi/camera_session_overrides.json 2>/dev/null || echo 'ファイルなし'" >> "$DIAG_FILE" 2>&1

echo "" >> "$DIAG_FILE"
echo "=== camera_settings.json 生データ ===" | tee -a "$DIAG_FILE"
ssh -o ConnectTimeout=10 "pi@$PI_HOST" \
    "cat /home/pi/camera_settings.json" >> "$DIAG_FILE" 2>&1

echo "" >> "$DIAG_FILE"
echo "=== テスト撮影 ===" | tee -a "$DIAG_FILE"
curl -s -X POST "http://$PI_HOST:8001/api/capture" \
    -H "Content-Type: application/json" -d '{}' 2>&1 | python3 -m json.tool >> "$DIAG_FILE" 2>&1

echo "" >> "$DIAG_FILE"
echo "=== テスト撮影後の api-server ログ ===" | tee -a "$DIAG_FILE"
sleep 3
ssh -o ConnectTimeout=10 "pi@$PI_HOST" \
    "journalctl -u api-server --no-pager -n 15 --since '30 sec ago'" >> "$DIAG_FILE" 2>&1

echo "" >> "$DIAG_FILE"
echo "=== テスト撮影後の camera-service ログ ===" | tee -a "$DIAG_FILE"
ssh -o ConnectTimeout=10 "pi@$PI_HOST" \
    "journalctl -u camera-service --no-pager -n 15 --since '30 sec ago'" >> "$DIAG_FILE" 2>&1

echo "" >> "$DIAG_FILE"
echo "=== 最新の写真ファイル情報 ===" | tee -a "$DIAG_FILE"
ssh -o ConnectTimeout=10 "pi@$PI_HOST" \
    "ls -lt /home/pi/photos/ | head -5" >> "$DIAG_FILE" 2>&1

echo "" >> "$DIAG_FILE"
echo "=== 最新写真のEXIF/サイズ ===" | tee -a "$DIAG_FILE"
ssh -o ConnectTimeout=10 "pi@$PI_HOST" \
    'LATEST=$(ls -t /home/pi/photos/*.jpg 2>/dev/null | head -1); if [ -n "$LATEST" ]; then echo "File: $LATEST"; ls -la "$LATEST"; python3 -c "from PIL import Image; im=Image.open(\"$LATEST\"); print(\"Size:\", im.size); import struct; exif=im.info.get(\"exif\",b\"\"); print(\"EXIF len:\", len(exif))" 2>/dev/null || echo "PIL not available"; python3 -c "import json,subprocess; r=subprocess.run([\"exiftool\",\"$LATEST\"],capture_output=True,text=True); print(r.stdout[:2000])" 2>/dev/null || echo "exiftool not available"; fi' >> "$DIAG_FILE" 2>&1

echo "" >> "$DIAG_FILE"
echo "=== リソース状況 ===" | tee -a "$DIAG_FILE"
ssh -o ConnectTimeout=10 "pi@$PI_HOST" \
    "free -h; echo '---'; df -h /; echo '---'; vcgencmd measure_temp; uptime" >> "$DIAG_FILE" 2>&1

# 3. Aaa に戻る
echo "" | tee -a "$DIAG_FILE"
echo ">>> Aaa WiFiに戻り中..." | tee -a "$DIAG_FILE"
networksetup -setairportnetwork en0 "$RETURN_SSID" 2>&1 | tee -a "$DIAG_FILE"

echo "完了: $(date)" | tee -a "$DIAG_FILE"
echo "結果: $DIAG_FILE"
