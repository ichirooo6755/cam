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
scp camera_service.py pi@$RASPI_HOST:/home/pi/
scp api_server.py pi@$RASPI_HOST:/home/pi/
scp camera_control.py pi@$RASPI_HOST:/home/pi/
scp shutter_trigger.py pi@$RASPI_HOST:/home/pi/
scp light_detection_algorithm.py pi@$RASPI_HOST:/home/pi/
scp server.py pi@$RASPI_HOST:/home/pi/
scp camera-control.service pi@$RASPI_HOST:/home/pi/
scp camera-service.service pi@$RASPI_HOST:/home/pi/
scp api-server.service pi@$RASPI_HOST:/home/pi/

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
ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no -tt pi@$RASPI_HOST "sudo -n sh -c 'echo 1 > /run/picamera_boot_network_applied'; if [ \$? -ne 0 ]; then echo 'Skip restart: sudo -n is not permitted'; exit 0; fi; if [ -f /home/pi/camera-service.service ]; then sudo -n install -m 644 /home/pi/camera-service.service /etc/systemd/system/camera-service.service; fi; if [ -f /home/pi/api-server.service ]; then sudo -n install -m 644 /home/pi/api-server.service /etc/systemd/system/api-server.service; fi; sudo -n systemctl daemon-reload; sudo -n systemctl stop camera-control 2>/dev/null; sudo -n systemctl disable camera-control 2>/dev/null; sudo systemctl restart camera-service api-server"

echo "Update finished successfully!"
