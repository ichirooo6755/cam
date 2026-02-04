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
scp camera-control.service pi@$RASPI_HOST:/home/pi/

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
ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no -tt pi@$RASPI_HOST "sudo -n sh -c 'echo 1 > /run/picamera_boot_network_applied'; if [ \$? -ne 0 ]; then echo 'Skip restart: sudo -n is not permitted'; exit 0; fi; if [ -f /home/pi/camera-control.service ]; then sudo -n install -m 644 /home/pi/camera-control.service /etc/systemd/system/camera-control.service; fi; sudo -n systemctl daemon-reload; sudo systemctl restart camera-control shutter-trigger photo-server"

echo "Update finished successfully!"
