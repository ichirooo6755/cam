#!/bin/bash
set -e

RASPI_HOST="${1:-192.168.0.20}"
RASPI_USER="pi"

echo "Deploying to $RASPI_USER@$RASPI_HOST..."

# ファイル転送
echo "Transferring files..."
scp camera_service.py $RASPI_USER@$RASPI_HOST:/home/pi/
scp api_server.py $RASPI_USER@$RASPI_HOST:/home/pi/
scp camera-service.service $RASPI_USER@$RASPI_HOST:/home/pi/
scp api-server.service $RASPI_USER@$RASPI_HOST:/home/pi/

# サービスインストールと起動
echo "Installing and starting services..."
ssh $RASPI_USER@$RASPI_HOST << 'ENDSSH'
# 古いサービスを停止（存在する場合）
sudo systemctl stop camera-control 2>/dev/null || true
sudo systemctl stop shutter-trigger 2>/dev/null || true
sudo systemctl stop photo-server 2>/dev/null || true

# 新しいサービスをインストール
sudo cp /home/pi/camera-service.service /etc/systemd/system/
sudo cp /home/pi/api-server.service /etc/systemd/system/

# systemd再読み込み
sudo systemctl daemon-reload

# サービス有効化と起動
sudo systemctl enable camera-service
sudo systemctl enable api-server
sudo systemctl restart camera-service
sudo systemctl restart api-server

# 状態確認
sleep 2
sudo systemctl status camera-service --no-pager | head -20
sudo systemctl status api-server --no-pager | head -20

# 写真ディレクトリ作成
mkdir -p /home/pi/photos

echo "Deployment complete!"
ENDSSH

echo "Done! Services are running on $RASPI_HOST"
echo "API: http://$RASPI_HOST:8001/api/photos"
