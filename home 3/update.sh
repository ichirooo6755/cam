#!/bin/bash

 set -e

# Raspberry PiのIPアドレス（引数で指定可能、デフォルトは raspberrypi.local）
RASPI_HOST="${1:-raspberrypi.local}"

 SSH_OPTS=(
     -o ConnectTimeout=10
     -o StrictHostKeyChecking=accept-new
 )

 # 再起動コマンドは負荷が高く banner が遅れることがあるため長めに取る
 RESTART_SSH_OPTS=(
     -o ConnectTimeout=30
     -o ServerAliveInterval=5
     -o ServerAliveCountMax=4
     -o StrictHostKeyChecking=accept-new
 )

# 非対話環境: SSHPASS が設定されていて sshpass がある場合にパスワード認証で接続
if [[ -n "${SSHPASS:-}" ]] && command -v sshpass >/dev/null 2>&1; then
  _SSH=(sshpass -e ssh)
  _SCP=(sshpass -e scp)
else
  _SSH=(ssh)
  _SCP=(scp)
fi

echo "Using Raspberry Pi: $RASPI_HOST"

 echo "Checking SSH host key..."
 CHECK_OUTPUT=$("${_SSH[@]}" "${SSH_OPTS[@]}" -T "pi@$RASPI_HOST" "echo ok" 2>&1 || true)
 if echo "$CHECK_OUTPUT" | grep -qE "REMOTE HOST IDENTIFICATION HAS CHANGED|Host key verification failed"; then
     echo "Host key mismatch detected. Fixing ~/.ssh/known_hosts entry for $RASPI_HOST ..."
     ssh-keygen -R "$RASPI_HOST" >/dev/null 2>&1 || true
     "${_SSH[@]}" "${SSH_OPTS[@]}" -T "pi@$RASPI_HOST" "echo ok" >/dev/null
 fi

echo "Starting file transfer..."

# 現在のディレクトリを取得
CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
echo "Source directory: $CURRENT_DIR"
cd "$CURRENT_DIR"

# Pythonスクリプトの転送
echo "Transffering Python scripts..."
"${_SCP[@]}" "${SSH_OPTS[@]}" wifi_manager.py pi@$RASPI_HOST:/home/pi/
"${_SCP[@]}" "${SSH_OPTS[@]}" camera_service.py pi@$RASPI_HOST:/home/pi/
"${_SCP[@]}" "${SSH_OPTS[@]}" api_server.py pi@$RASPI_HOST:/home/pi/
"${_SCP[@]}" "${SSH_OPTS[@]}" metering_calibrate.py pi@$RASPI_HOST:/home/pi/
"${_SCP[@]}" "${SSH_OPTS[@]}" enable_usb_otg_gadget.sh pi@$RASPI_HOST:/home/pi/
"${_SCP[@]}" "${SSH_OPTS[@]}" camera-service.service pi@$RASPI_HOST:/home/pi/
"${_SCP[@]}" "${SSH_OPTS[@]}" api-server.service pi@$RASPI_HOST:/home/pi/
"${_SCP[@]}" "${SSH_OPTS[@]}" usb0-static-ip.service pi@$RASPI_HOST:/home/pi/

# 性能調整スクリプトと zram-tools オフライン用 deb（AP でも tune が完走しやすい）
if [[ -f "$CURRENT_DIR/tune_performance_zero2w.sh" ]]; then
  "${_SCP[@]}" "${SSH_OPTS[@]}" "$CURRENT_DIR/tune_performance_zero2w.sh" pi@$RASPI_HOST:/home/pi/
fi
shopt -s nullglob
for ZDEB in "$CURRENT_DIR"/vendor/debian/zram-tools_*_all.deb; do
  "${_SCP[@]}" "${SSH_OPTS[@]}" "$ZDEB" pi@$RASPI_HOST:/home/pi/
done
shopt -u nullglob

# ドキュメントの転送（オプション）
"${_SCP[@]}" "${SSH_OPTS[@]}" ../docs/runbook/TROUBLESHOOTING.md pi@$RASPI_HOST:/home/pi/ 2>/dev/null || echo "TROUBLESHOOTING.md not found, skipping..."

echo "Transfer complete."

# OTG usb0 の固定 IP（replace で冪等）。sudo パスワード不要（NOPASSWD）でない環境ではスキップされうる
echo "Installing usb0-static-ip.service (if possible)..."
"${_SSH[@]}" "${SSH_OPTS[@]}" -T pi@$RASPI_HOST "if [ -f /home/pi/usb0-static-ip.service ]; then sudo -n install -m 644 /home/pi/usb0-static-ip.service /etc/systemd/system/usb0-static-ip.service && sudo -n systemctl daemon-reload && sudo -n systemctl enable usb0-static-ip.service && sudo -n systemctl restart usb0-static-ip.service && echo 'usb0-static-ip: ok' || echo 'WARN: usb0-static-ip skipped (sudo -n not allowed or systemctl failed)'; else echo 'usb0-static-ip.service not on Pi, skip'; fi" || echo "WARN: usb0-static-ip SSH step failed"

echo "Restarting services..."

# サービスの再起動（最大3回、TTY 無しで banner 待ちを短縮）
_restart_remote() {
  "${_SSH[@]}" "${RESTART_SSH_OPTS[@]}" -T pi@$RASPI_HOST "sudo -n sh -c 'echo 1 > /run/picamera_boot_network_applied'; if [ \$? -ne 0 ]; then echo 'Skip restart: sudo -n is not permitted'; exit 0; fi; sudo -n systemctl stop camera-control 2>/dev/null; sudo -n systemctl disable camera-control 2>/dev/null; sudo -n systemctl stop shutter-trigger 2>/dev/null; sudo -n systemctl disable shutter-trigger 2>/dev/null; sudo -n systemctl stop photo-server 2>/dev/null; sudo -n systemctl disable photo-server 2>/dev/null; sudo -n rm -f /etc/systemd/system/camera-control.service /etc/systemd/system/shutter-trigger.service /etc/systemd/system/photo-server.service 2>/dev/null || true; sudo -n rm -f /home/pi/camera_control.py /home/pi/shutter_trigger.py /home/pi/light_detection_algorithm.py /home/pi/server.py /home/pi/index.html /home/pi/gallery.html /home/pi/style.css 2>/dev/null || true; if [ -f /home/pi/camera-service.service ]; then sudo -n install -m 644 /home/pi/camera-service.service /etc/systemd/system/camera-service.service; fi; if [ -f /home/pi/api-server.service ]; then sudo -n install -m 644 /home/pi/api-server.service /etc/systemd/system/api-server.service; fi; sudo -n systemctl daemon-reload; sudo -n systemctl enable camera-service api-server 2>/dev/null || true; sudo -n systemctl restart camera-service api-server"
}

_ok=0
for _attempt in 1 2 3; do
  if _restart_remote; then
    _ok=1
    break
  fi
  echo "Restart SSH failed (attempt ${_attempt}/3), retrying in 5s..."
  sleep 5
done
if [[ "${_ok}" -ne 1 ]]; then
  echo "ERROR: Service restart failed after 3 attempts. Files were copied; run on Pi: sudo systemctl restart api-server camera-service"
  exit 255
fi

# sshd の DNS 逆引き無効化（初回のみ、SSH banner exchange タイムアウト対策）
"${_SSH[@]}" "${SSH_OPTS[@]}" pi@$RASPI_HOST "grep -q 'UseDNS no' /etc/ssh/sshd_config || (echo 'UseDNS no' | sudo tee -a /etc/ssh/sshd_config && sudo systemctl restart ssh)" || true

echo "Update finished successfully!"
