#!/usr/bin/env bash
# Pi Zero 2 W 向けシステムチューニング（512MB RAM）
# - zram 優先スワップ（SD  thrashing 抑制）
# - 小さめ dphys-swapfile（zram 併用時の保険）
# - fake-hwclock + systemd-timesyncd（AP 時は iPhone 同期）
# - sysctl / CPU governor / I/O scheduler
#
# 用法:
#   sudo bash setup_zero2w_system.sh           # フル適用（update.sh から）
#   sudo bash setup_zero2w_system.sh --boot-only
#   sudo bash setup_zero2w_system.sh --time-sync-only
set -euo pipefail

MODE="${1:---full}"
SWAP_MB="${SWAP_MB:-128}"
ZRAM_PERCENT="${ZRAM_PERCENT:-50}"
ZRAM_PRIORITY="${ZRAM_PRIORITY:-100}"
LOG_TAG="setup_zero2w"

log() { echo "[$LOG_TAG] $*"; }
warn() { echo "[$LOG_TAG] WARN: $*" >&2; }

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    exec sudo -n bash "$0" "$@" 2>/dev/null || exec sudo bash "$0" "$@"
  fi
}

install_zram_tools_if_needed() {
  if dpkg -s zram-tools >/dev/null 2>&1; then
    log "zram-tools: already installed"
    return 0
  fi

  local deb_path="${ZRAM_TOOLS_DEB:-}"
  if [[ -z "${deb_path}" ]]; then
    local f
    for f in /home/pi/zram-tools_*_all.deb; do
      if [[ -f "${f}" ]]; then
        deb_path="${f}"
        break
      fi
    done
  fi

  if [[ -n "${deb_path}" && -f "${deb_path}" ]]; then
    log "zram-tools: installing from ${deb_path}"
    if ! dpkg -i "${deb_path}"; then
      if ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1; then
        apt-get -f install -y
      else
        warn "dpkg failed and offline — continuing without zram-tools"
        return 1
      fi
    fi
    return 0
  fi

  if ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1; then
    log "zram-tools: installing via apt"
    apt-get update -qq
    apt-get install -y zram-tools
    return 0
  fi

  warn "zram-tools not available (no deb, no network)"
  return 1
}

install_fake_hwclock_if_needed() {
  if command -v fake-hwclock >/dev/null 2>&1; then
    return 0
  fi
  if ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1; then
    log "fake-hwclock: installing via apt"
    apt-get install -y fake-hwclock
    systemctl enable fake-hwclock.service 2>/dev/null || true
    return 0
  fi
  warn "fake-hwclock not installed (offline)"
  return 1
}

apply_sysctl() {
  local src="/home/pi/sysctl-picamera-zero2w.conf"
  if [[ ! -f "${src}" ]]; then
    warn "missing ${src}"
    return 0
  fi
  install -m 644 "${src}" /etc/sysctl.d/99-picamera-zero2w.conf
  sysctl --system >/dev/null 2>&1 || sysctl -p /etc/sysctl.d/99-picamera-zero2w.conf || true
  log "sysctl applied"
}

apply_timesyncd() {
  local src="/home/pi/timesync-picamera.conf"
  mkdir -p /etc/systemd/timesyncd.conf.d
  if [[ -f "${src}" ]]; then
    install -m 644 "${src}" /etc/systemd/timesyncd.conf.d/picamera.conf
  fi
  systemctl enable systemd-timesyncd.service 2>/dev/null || true
  systemctl restart systemd-timesyncd.service 2>/dev/null || true
  log "systemd-timesyncd configured"
}

restore_and_save_hwclock() {
  if command -v fake-hwclock >/dev/null 2>&1; then
    fake-hwclock load 2>/dev/null || true
    log "fake-hwclock load: $(date '+%Y-%m-%d %H:%M:%S %Z')"
  fi
  timedatectl set-ntp true 2>/dev/null || true
  if command -v fake-hwclock >/dev/null 2>&1; then
    fake-hwclock save 2>/dev/null || true
  fi
}

configure_zram() {
  install_zram_tools_if_needed || return 0

  mkdir -p /etc/default
  if [[ -f /etc/default/zramswap ]]; then
    sed -i "s/^#\\?ALGO=.*/ALGO=lz4/" /etc/default/zramswap
    sed -i "s/^#\\?PERCENT=.*/PERCENT=${ZRAM_PERCENT}/" /etc/default/zramswap
    sed -i "s/^#\\?PRIORITY=.*/PRIORITY=${ZRAM_PRIORITY}/" /etc/default/zramswap
  else
    cat >/etc/default/zramswap <<EOF
ALGO=lz4
PERCENT=${ZRAM_PERCENT}
PRIORITY=${ZRAM_PRIORITY}
EOF
  fi

  systemctl enable zramswap.service 2>/dev/null || true
  systemctl restart zramswap.service 2>/dev/null || true
  log "zram: ${ZRAM_PERCENT}% lz4 priority=${ZRAM_PRIORITY}"
}

configure_swapfile() {
  # zram がある環境では SD swap を小さく（128MB 保険）
  if ! command -v dphys-swapfile >/dev/null 2>&1; then
    if ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1; then
      apt-get install -y dphys-swapfile
    else
      warn "dphys-swapfile not available"
      return 0
    fi
  fi

  if [[ -f /etc/dphys-swapfile ]]; then
    if grep -q '^CONF_SWAPSIZE=' /etc/dphys-swapfile; then
      sed -i "s/^CONF_SWAPSIZE=.*/CONF_SWAPSIZE=${SWAP_MB}/" /etc/dphys-swapfile
    else
      echo "CONF_SWAPSIZE=${SWAP_MB}" >>/etc/dphys-swapfile
    fi
  else
    echo "CONF_SWAPSIZE=${SWAP_MB}" >/etc/dphys-swapfile
  fi

  dphys-swapfile swapoff 2>/dev/null || true
  dphys-swapfile setup
  dphys-swapfile swapon 2>/dev/null || true
  log "swapfile: ${SWAP_MB}MB (fallback; zram preferred)"
}

apply_io_and_cpu_defaults() {
  # 撮影サービス起動時にも設定するが、起動前の I/O も改善
  if [[ -f /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor ]]; then
    echo performance >/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || true
  fi
  if [[ -f /sys/block/mmcblk0/queue/scheduler ]]; then
    echo deadline >/sys/block/mmcblk0/queue/scheduler 2>/dev/null || true
  fi
  log "cpu governor=performance, mmc scheduler=deadline (best effort)"
}

install_systemd_units() {
  for unit in picamera-time-sync.service picamera-system-tune.service; do
    if [[ -f "/home/pi/${unit}" ]]; then
      install -m 644 "/home/pi/${unit}" "/etc/systemd/system/${unit}"
    fi
  done
  systemctl daemon-reload
  systemctl enable picamera-time-sync.service picamera-system-tune.service 2>/dev/null || true
  log "systemd units installed"
}

print_status() {
  echo "---- $(date '+%Y-%m-%d %H:%M:%S %Z') ----"
  timedatectl status 2>/dev/null | head -8 || true
  free -h 2>/dev/null || true
  swapon --show 2>/dev/null || true
  zramctl 2>/dev/null || true
}

time_sync_only() {
  require_root "$@"
  install_fake_hwclock_if_needed || true
  apply_timesyncd
  restore_and_save_hwclock
  print_status
}

boot_only() {
  require_root "$@"
  apply_sysctl
  apply_io_and_cpu_defaults
  configure_zram
  configure_swapfile
  print_status
}

full_setup() {
  require_root "$@"
  log "full setup for Pi Zero 2 W"
  install_fake_hwclock_if_needed || true
  apply_sysctl
  apply_timesyncd
  restore_and_save_hwclock
  configure_zram
  configure_swapfile
  apply_io_and_cpu_defaults
  install_systemd_units
  print_status
  log "done"
}

case "${MODE}" in
  --time-sync-only) time_sync_only "$@" ;;
  --boot-only) boot_only "$@" ;;
  --full|--full-setup|"") full_setup "$@" ;;
  *)
    echo "Usage: $0 [--full|--boot-only|--time-sync-only]" >&2
    exit 2
    ;;
esac
