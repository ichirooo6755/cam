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

echo "[1/5] Install zram-tools (if missing)..."
sudo apt-get update -y
sudo apt-get install -y zram-tools

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
sudo systemctl restart picamera-api camera-service

echo
echo "Done."
echo "---- Runtime check ----"
free -h || true
swapon --show || true
curl -sS --max-time 8 "http://127.0.0.1:8001/api/sensor/status" || true
