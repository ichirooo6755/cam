#!/bin/bash

# Raspberry PiのIPアドレス（引数で指定可能、デフォルトは raspberrypi.local）
RASPI_HOST="${1:-raspberrypi.local}"

echo "Using Raspberry Pi: $RASPI_HOST"
echo "Starting file transfer..."

# 現在のディレクトリを取得
CURRENT_DIR=$(pwd)
echo "Source directory: $CURRENT_DIR"

# Pythonスクリプトの転送
echo "Transffering Python scripts..."
scp wifi_manager.py pi@$RASPI_HOST:/home/pi/
scp camera_control.py pi@$RASPI_HOST:/home/pi/
scp shutter_trigger.py pi@$RASPI_HOST:/home/pi/
scp light_detection_algorithm.py pi@$RASPI_HOST:/home/pi/
scp server.py pi@$RASPI_HOST:/home/pi/

# Webファイルの転送
echo "Transffering Web files..."
scp index.html pi@$RASPI_HOST:/home/pi/
scp gallery.html pi@$RASPI_HOST:/home/pi/
scp style.css pi@$RASPI_HOST:/home/pi/

# READMEの転送（オプション）
scp README.md pi@$RASPI_HOST:/home/pi/

echo "Transfer complete."
echo "Restarting services..."

# サービスの再起動
ssh pi@$RASPI_HOST "sudo systemctl restart camera-control shutter-trigger photo-server"

echo "Update finished successfully!"
