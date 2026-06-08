#!/bin/bash

 set -e

# Raspberry PiのIPアドレス（引数で指定可能、デフォルトは raspberrypi.local）
# 到達不能時は PI_FALLBACK_HOSTS（空白区切り）を順に試す（OTG→AP→mDNS 想定）

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

# AP 経由の scp は遅くハングしやすいため、Python/シェルは SSH stdin パイプを優先
_pipe_deploy_file() {
  local src="$1"
  local dest="$2"
  local base
  base="$(basename "$src")"
  echo "  pipe: $base -> $dest"
  "${_SSH[@]}" "${SSH_OPTS[@]}" -T "pi@$RASPI_HOST" "cat > '$dest'" < "$src"
}

_scp_or_pipe() {
  local src="$1"
  local dest="$2"
  case "$src" in
    *.py|*.sh|*.service|*.conf)
      _pipe_deploy_file "$src" "$dest"
      ;;
    *)
      "${_SCP[@]}" "${SSH_OPTS[@]}" "$src" "pi@$RASPI_HOST:$dest"
      ;;
  esac
}

_try_ssh_reach() {
  local h="$1"
  "${_SSH[@]}" "${SSH_OPTS[@]}" -T "pi@$h" "echo ok" >/dev/null 2>&1
}

_primary="${1:-raspberrypi.local}"
RASPI_HOST="$_primary"
_fb="${PI_FALLBACK_HOSTS:-192.168.7.2 192.168.4.1 raspberrypi.local raspberrypi}"

if ! _try_ssh_reach "$RASPI_HOST"; then
  echo "Primary host unreachable: $_primary — trying PI_FALLBACK_HOSTS..."
  RASPI_HOST=""
  for _h in $_fb; do
    [[ "$_h" == "$_primary" ]] && continue
    if _try_ssh_reach "$_h"; then
      RASPI_HOST="$_h"
      break
    fi
  done
  if [[ -z "$RASPI_HOST" ]]; then
    echo "ERROR: SSH failed for $_primary and fallbacks: $_fb"
    exit 255
  fi
fi

echo "Using Raspberry Pi: $RASPI_HOST"

echo "Checking Python syntax..."
python3 -m py_compile api_server.py camera_service.py wifi_manager.py metering_calibrate.py

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

# Pythonスクリプトの転送（1回の SSH + tar で AP 瞬断に強くする）
_deploy_payload_tar() {
  echo "Transferring payload (single tar stream)..."
  local -a _files=(
    wifi_manager.py camera_service.py api_server.py metering_calibrate.py
    enable_usb_otg_gadget.sh camera-service.service api-server.service
    usb0-static-ip.service picamera-wifi-bootstrap.sh picamera-wifi-bootstrap.service
    journald-persistent.conf setup_zero2w_system.sh tune_performance_zero2w.sh
    sysctl-picamera-zero2w.conf timesync-picamera.conf
    picamera-time-sync.service picamera-system-tune.service
  )
  local -a _present=()
  local f
  for f in "${_files[@]}"; do
    [[ -f "$CURRENT_DIR/$f" ]] && _present+=("$f")
  done
  if [[ ${#_present[@]} -eq 0 ]]; then
    echo "WARN: no payload files to transfer"
    return 1
  fi
  tar czf - -C "$CURRENT_DIR" "${_present[@]}" | \
    "${_SSH[@]}" "${SSH_OPTS[@]}" -T "pi@$RASPI_HOST" "cd /home/pi && tar xzf -"
}

_pipe_deploy_binary() {
  local src="$1"
  local dest="$2"
  echo "  pipe(binary): $(basename "$src") -> $dest"
  "${_SSH[@]}" "${SSH_OPTS[@]}" -T "pi@$RASPI_HOST" "cat > '$dest'" < "$src"
}

echo "Transffering Python scripts..."
if ! _deploy_payload_tar; then
  echo "WARN: tar deploy failed — falling back to per-file pipe"
  _scp_or_pipe wifi_manager.py /home/pi/wifi_manager.py
  _scp_or_pipe camera_service.py /home/pi/camera_service.py
  _scp_or_pipe api_server.py /home/pi/api_server.py
  _scp_or_pipe metering_calibrate.py /home/pi/metering_calibrate.py
  _scp_or_pipe enable_usb_otg_gadget.sh /home/pi/enable_usb_otg_gadget.sh
  _scp_or_pipe camera-service.service /home/pi/camera-service.service
  _scp_or_pipe api-server.service /home/pi/api-server.service
  _scp_or_pipe usb0-static-ip.service /home/pi/usb0-static-ip.service
  _scp_or_pipe picamera-wifi-bootstrap.sh /home/pi/picamera-wifi-bootstrap.sh
  _scp_or_pipe picamera-wifi-bootstrap.service /home/pi/picamera-wifi-bootstrap.service
  [[ -f "$CURRENT_DIR/journald-persistent.conf" ]] && _scp_or_pipe journald-persistent.conf /home/pi/journald-persistent.conf
  [[ -f "$CURRENT_DIR/setup_zero2w_system.sh" ]] && _scp_or_pipe setup_zero2w_system.sh /home/pi/setup_zero2w_system.sh
  [[ -f "$CURRENT_DIR/tune_performance_zero2w.sh" ]] && _scp_or_pipe tune_performance_zero2w.sh /home/pi/tune_performance_zero2w.sh
  [[ -f "$CURRENT_DIR/sysctl-picamera-zero2w.conf" ]] && _scp_or_pipe sysctl-picamera-zero2w.conf /home/pi/sysctl-picamera-zero2w.conf
  [[ -f "$CURRENT_DIR/timesync-picamera.conf" ]] && _scp_or_pipe timesync-picamera.conf /home/pi/timesync-picamera.conf
  _scp_or_pipe picamera-time-sync.service /home/pi/picamera-time-sync.service
  _scp_or_pipe picamera-system-tune.service /home/pi/picamera-system-tune.service
fi

# zram-tools オフライン deb
shopt -s nullglob
for ZDEB in "$CURRENT_DIR"/vendor/debian/zram-tools_*_all.deb; do
  _pipe_deploy_binary "$ZDEB" "/home/pi/$(basename "$ZDEB")"
done
shopt -u nullglob

# ドキュメントの転送（オプション）
"${_SCP[@]}" "${SSH_OPTS[@]}" ../docs/runbook/TROUBLESHOOTING.md pi@$RASPI_HOST:/home/pi/ 2>/dev/null || echo "TROUBLESHOOTING.md not found, skipping..."

echo "Transfer complete."

# OTG usb0 の固定 IP（replace で冪等）。sudo パスワード不要（NOPASSWD）でない環境ではスキップされうる
echo "Installing usb0-static-ip.service (if possible)..."
"${_SSH[@]}" "${SSH_OPTS[@]}" -T pi@$RASPI_HOST "if [ -f /home/pi/usb0-static-ip.service ]; then sudo -n install -m 644 /home/pi/usb0-static-ip.service /etc/systemd/system/usb0-static-ip.service && sudo -n systemctl daemon-reload && sudo -n systemctl enable usb0-static-ip.service && sudo -n systemctl restart usb0-static-ip.service && echo 'usb0-static-ip: ok' || echo 'WARN: usb0-static-ip skipped (sudo -n not allowed or systemctl failed)'; else echo 'usb0-static-ip.service not on Pi, skip'; fi" || echo "WARN: usb0-static-ip SSH step failed"

echo "Installing persistent journald (if possible)..."
"${_SSH[@]}" "${SSH_OPTS[@]}" -T pi@$RASPI_HOST "if [ -f /home/pi/journald-persistent.conf ]; then sudo -n install -m 644 /home/pi/journald-persistent.conf /etc/systemd/journald.conf.d/picamera-persistent.conf 2>/dev/null || (sudo -n mkdir -p /etc/systemd/journald.conf.d && sudo -n install -m 644 /home/pi/journald-persistent.conf /etc/systemd/journald.conf.d/picamera-persistent.conf); sudo -n systemctl restart systemd-journald 2>/dev/null && echo 'journald-persistent: ok' || echo 'WARN: journald config skipped'; grep -E '^Storage=' /etc/systemd/journald.conf /etc/systemd/journald.conf.d/*.conf 2>/dev/null | tail -1 || true; journalctl --disk-usage 2>/dev/null || true; else echo 'journald-persistent.conf not on Pi, skip'; fi" || echo "WARN: journald SSH step failed"

echo "Applying Pi Zero 2W system tune (zram, swap, time sync)..."
"${_SSH[@]}" "${SSH_OPTS[@]}" -T pi@$RASPI_HOST "chmod +x /home/pi/setup_zero2w_system.sh /home/pi/tune_performance_zero2w.sh 2>/dev/null || true; if [ -x /home/pi/setup_zero2w_system.sh ]; then sudo -n bash /home/pi/setup_zero2w_system.sh --full && echo 'system-tune: ok' || echo 'WARN: system-tune failed (check sudo NOPASSWD)'; else echo 'setup_zero2w_system.sh not on Pi, skip'; fi" || echo "WARN: system-tune SSH step failed"

echo "Restarting services..."

# サービスの再起動（最大3回、TTY 無しで banner 待ちを短縮）
_restart_remote() {
  "${_SSH[@]}" "${RESTART_SSH_OPTS[@]}" -T pi@$RASPI_HOST "sudo -n sh -c 'echo 1 > /run/picamera_boot_network_applied'; if [ \$? -ne 0 ]; then echo 'Skip restart: sudo -n is not permitted'; exit 0; fi; mkdir -p /home/pi/logs /run/picamera/capture_results; if [ -f /home/pi/picamera-time-sync.service ]; then sudo -n install -m 644 /home/pi/picamera-time-sync.service /etc/systemd/system/picamera-time-sync.service; fi; if [ -f /home/pi/picamera-system-tune.service ]; then sudo -n install -m 644 /home/pi/picamera-system-tune.service /etc/systemd/system/picamera-system-tune.service; fi; sudo -n systemctl enable picamera-time-sync.service picamera-system-tune.service 2>/dev/null || true; sudo -n systemctl stop camera-control 2>/dev/null; sudo -n systemctl disable camera-control 2>/dev/null; sudo -n systemctl stop shutter-trigger 2>/dev/null; sudo -n systemctl disable shutter-trigger 2>/dev/null; sudo -n systemctl stop photo-server 2>/dev/null; sudo -n systemctl disable photo-server 2>/dev/null; sudo -n rm -f /etc/systemd/system/camera-control.service /etc/systemd/system/shutter-trigger.service /etc/systemd/system/photo-server.service 2>/dev/null || true; sudo -n rm -f /home/pi/camera_control.py /home/pi/shutter_trigger.py /home/pi/light_detection_algorithm.py /home/pi/server.py /home/pi/index.html /home/pi/gallery.html /home/pi/style.css 2>/dev/null || true; if [ -f /home/pi/camera-service.service ]; then sudo -n install -m 644 /home/pi/camera-service.service /etc/systemd/system/camera-service.service; fi; if [ -f /home/pi/api-server.service ]; then sudo -n install -m 644 /home/pi/api-server.service /etc/systemd/system/api-server.service; fi; if [ -f /home/pi/picamera-wifi-bootstrap.service ]; then sudo -n install -m 644 /home/pi/picamera-wifi-bootstrap.service /etc/systemd/system/picamera-wifi-bootstrap.service; fi; sudo -n chmod 755 /home/pi/picamera-wifi-bootstrap.sh 2>/dev/null || true; sudo -n systemctl daemon-reload; sudo -n systemctl enable picamera-wifi-bootstrap.service 2>/dev/null || true; sudo -n systemctl start picamera-wifi-bootstrap.service 2>/dev/null || true; sudo -n systemctl enable camera-service api-server 2>/dev/null || true; sudo -n systemctl restart camera-service api-server"
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
