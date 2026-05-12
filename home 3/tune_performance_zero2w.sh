#!/usr/bin/env bash
set -euo pipefail

# Pi Zero 2 W 向け:
# - swap を適正化（512MB）
# - zram を有効化（RAM圧縮スワップ）
# - API/撮影設定を安定寄りへ調整
# - capture_cooldown は 1.5 秒に固定

SWAP_MB="${SWAP_MB:-512}"
ZRAM_PERCENT="${ZRAM_PERCENT:-35}"
TARGET_SETTINGS_FILE="/home/pi/camera_settings.json"

# zram-tools: ネット無し（AP のみ）でも進められるよう、ローカル .deb / 既存導入を優先
install_zram_tools_if_needed() {
  if dpkg -s zram-tools >/dev/null 2>&1; then
    echo "zram-tools は既にインストール済み"
    return 0
  fi

  local deb_path="${ZRAM_TOOLS_DEB:-}"
  if [[ -z "${deb_path}" ]]; then
    # update.sh が vendor の deb を /home/pi に置いた場合
    local f
    for f in /home/pi/zram-tools_*_all.deb; do
      if [[ -f "${f}" ]]; then
        deb_path="${f}"
        break
      fi
    done
  fi

  if [[ -n "${deb_path}" && -f "${deb_path}" ]]; then
    echo "zram-tools をローカル deb から導入: ${deb_path}"
    if ! sudo dpkg -i "${deb_path}"; then
      if ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1; then
        sudo apt-get -f install -y
      else
        echo "ERROR: dpkg が失敗し、オフラインのため apt-get -f も使えません（swap 以降は続行）"
      fi
    fi
    return 0
  fi

  # インターネット到達の粗い判定（DNS 失敗で apt が長時間ハングしないようにする）
  if ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1; then
    echo "apt で zram-tools を導入（ネット到達あり）..."
    sudo apt-get update -y
    sudo apt-get install -y zram-tools
    return 0
  fi

  echo "WARN: zram-tools 未導入（ネット無し・deb 無し）。以下のいずれかで対応してください:"
  echo "  - Mac から: scp home 3/vendor/debian/zram-tools_*_all.deb pi@<host>:/home/pi/"
  echo "  - 環境変数: ZRAM_TOOLS_DEB=/path/to/zram-tools_*_all.deb bash $0"
  return 0
}

echo "[1/5] Install zram-tools (if missing)..."
install_zram_tools_if_needed

echo "[2/5] Configure swapfile size: ${SWAP_MB}MB"
if [[ -f /etc/dphys-swapfile ]]; then
  sudo sed -i "s/^CONF_SWAPSIZE=.*/CONF_SWAPSIZE=${SWAP_MB}/" /etc/dphys-swapfile
else
  echo "CONF_SWAPSIZE=${SWAP_MB}" | sudo tee /etc/dphys-swapfile >/dev/null
fi
sudo dphys-swapfile swapoff || true
sudo dphys-swapfile setup
sudo dphys-swapfile swapon

echo "[3/5] Configure zram: percent=${ZRAM_PERCENT}%"
if [[ -f /etc/default/zramswap ]]; then
  sudo sed -i "s/^#\\?ALGO=.*/ALGO=lz4/" /etc/default/zramswap
  sudo sed -i "s/^#\\?PERCENT=.*/PERCENT=${ZRAM_PERCENT}/" /etc/default/zramswap
  sudo sed -i "s/^#\\?PRIORITY=.*/PRIORITY=100/" /etc/default/zramswap
else
  cat <<EOF | sudo tee /etc/default/zramswap >/dev/null
ALGO=lz4
PERCENT=${ZRAM_PERCENT}
PRIORITY=100
EOF
fi
sudo systemctl enable zramswap >/dev/null 2>&1 || true
sudo systemctl restart zramswap

echo "[4/5] Apply stable camera settings (cooldown=1.5s)"
sudo python3 - <<'PY'
import json
from pathlib import Path

path = Path("/home/pi/camera_settings.json")
if path.exists():
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        data = {}
else:
    data = {}

# 安定運用向け（Pi Zero 2 W）
data.update({
    "camera_mode": "standard",
    "monitoring_enabled": True,
    "brightness_threshold": 10,
    "detection_threshold": 10,
    "check_interval": 0.2,
    "capture_cooldown": 1.5,
    "quality": 90,
    "iso": "auto",
    "shutter_speed": "auto",
    "white_balance": "auto",
    "width": 1920,
    "height": 1080
})

path.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
print(f"updated: {path}")
PY

echo "[5/5] Restart services"
sudo systemctl restart api-server.service camera-service.service

echo
echo "Done."
echo "---- Runtime check ----"
free -h || true
swapon --show || true
curl -sS --max-time 8 "http://127.0.0.1:8001/api/sensor/status" || true
