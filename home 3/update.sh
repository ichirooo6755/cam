#!/bin/bash

 set -e

# Raspberry PiのIPアドレス（引数で指定可能、デフォルトは raspberrypi.local）
RASPI_HOST="${1:-raspberrypi.local}"

 SSH_OPTS=(
     -o ConnectTimeout=10
     -o StrictHostKeyChecking=accept-new
 )

echo "Using Raspberry Pi: $RASPI_HOST"

 echo "Checking SSH host key..."
 CHECK_OUTPUT=$(ssh "${SSH_OPTS[@]}" -T "pi@$RASPI_HOST" "echo ok" 2>&1 || true)
 if echo "$CHECK_OUTPUT" | grep -qE "REMOTE HOST IDENTIFICATION HAS CHANGED|Host key verification failed"; then
     echo "Host key mismatch detected. Fixing ~/.ssh/known_hosts entry for $RASPI_HOST ..."
     ssh-keygen -R "$RASPI_HOST" >/dev/null 2>&1 || true
     ssh "${SSH_OPTS[@]}" -T "pi@$RASPI_HOST" "echo ok" >/dev/null
 fi

echo "Starting file transfer..."

# 現在のディレクトリを取得
CURRENT_DIR=$(pwd)
echo "Source directory: $CURRENT_DIR"

# Pythonスクリプトの転送
echo "Transffering Python scripts..."
scp "${SSH_OPTS[@]}" wifi_manager.py pi@$RASPI_HOST:/home/pi/
scp "${SSH_OPTS[@]}" camera_service.py pi@$RASPI_HOST:/home/pi/
scp "${SSH_OPTS[@]}" api_server.py pi@$RASPI_HOST:/home/pi/
scp "${SSH_OPTS[@]}" camera_control.py pi@$RASPI_HOST:/home/pi/
scp "${SSH_OPTS[@]}" shutter_trigger.py pi@$RASPI_HOST:/home/pi/
scp "${SSH_OPTS[@]}" light_detection_algorithm.py pi@$RASPI_HOST:/home/pi/
scp "${SSH_OPTS[@]}" server.py pi@$RASPI_HOST:/home/pi/
scp "${SSH_OPTS[@]}" camera-control.service pi@$RASPI_HOST:/home/pi/
scp "${SSH_OPTS[@]}" camera-service.service pi@$RASPI_HOST:/home/pi/
scp "${SSH_OPTS[@]}" api-server.service pi@$RASPI_HOST:/home/pi/

# Webファイルの転送
echo "Transffering Web files..."
scp "${SSH_OPTS[@]}" index.html pi@$RASPI_HOST:/home/pi/
scp "${SSH_OPTS[@]}" gallery.html pi@$RASPI_HOST:/home/pi/
scp "${SSH_OPTS[@]}" style.css pi@$RASPI_HOST:/home/pi/

# READMEの転送（オプション）
scp "${SSH_OPTS[@]}" README.md pi@$RASPI_HOST:/home/pi/

echo "Transfer complete."
echo "Restarting services..."

# サービスの再起動
ssh "${SSH_OPTS[@]}" -tt pi@$RASPI_HOST "sudo -n sh -c 'echo 1 > /run/picamera_boot_network_applied'; if [ \$? -ne 0 ]; then echo 'Skip restart: sudo -n is not permitted'; exit 0; fi; if [ -f /home/pi/camera-service.service ]; then sudo -n install -m 644 /home/pi/camera-service.service /etc/systemd/system/camera-service.service; fi; if [ -f /home/pi/api-server.service ]; then sudo -n install -m 644 /home/pi/api-server.service /etc/systemd/system/api-server.service; fi; sudo -n systemctl daemon-reload; sudo -n systemctl stop camera-control 2>/dev/null; sudo -n systemctl disable camera-control 2>/dev/null; sudo systemctl restart camera-service api-server"

echo "Update finished successfully!"
