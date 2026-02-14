#!/usr/bin/env bash
set -euo pipefail

CYCLES="${1:-1}"
AP_HOST="${AP_HOST:-192.168.4.1}"
HOME_HOST="${HOME_HOST:-raspberrypi.local}"
HOME_IP="${HOME_IP:-192.168.0.20}"
HOME_MAC="${HOME_MAC:-88-A2-9E-40-1E-B4}"
AP_INTERFACE="${AP_INTERFACE:-}"
HOME_INTERFACE="${HOME_INTERFACE:-}"
HOME_SUBNET_PREFIX="${HOME_SUBNET_PREFIX:-192.168.0}"
STEP_WAIT_SEC="${STEP_WAIT_SEC:-2}"
AP_WAIT_SEC="${AP_WAIT_SEC:-120}"
HOME_WAIT_SEC="${HOME_WAIT_SEC:-90}"
CURL_TIMEOUT_SEC="${CURL_TIMEOUT_SEC:-3}"

TS="$(date '+%Y%m%d_%H%M%S')"
LOG_FILE="${LOG_FILE:-./wifi_cycle_test_${TS}.log}"
WAIT_HOST=""

log() {
  local msg="$*"
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$msg" | tee -a "$LOG_FILE"
}

detect_wifi_interface() {
  if command -v networksetup >/dev/null 2>&1; then
    networksetup -listallhardwareports 2>/dev/null |
      awk '
        /Hardware Port: Wi-Fi/ {getline; if ($1 == "Device:") {print $2; exit}}
      '
    return 0
  fi

  return 1
}

warn_route_interface_mismatch() {
  local host="$1"
  local requested_iface="$2"

  [ -z "$host" ] && return 0
  [ -z "$requested_iface" ] && return 0

  if ! command -v route >/dev/null 2>&1; then
    return 0
  fi

  local route_iface
  route_iface="$(route -n get "$host" 2>/dev/null | awk '/interface:/{print $2; exit}')"
  if [ -n "$route_iface" ] && [ "$route_iface" != "$requested_iface" ]; then
    log "WARN: route to ${host} is via ${route_iface} (requested ${requested_iface})."
  fi
}

normalize_mac() {
  echo "$1" | tr '[:upper:]' '[:lower:]' | tr '-' ':'
}

discover_home_host_by_mac() {
  local iface="$1"
  local target_mac
  target_mac="$(normalize_mac "$HOME_MAC")"
  [ -z "$target_mac" ] && return 1

  if command -v fping >/dev/null 2>&1; then
    fping -a -q -g "${HOME_SUBNET_PREFIX}.0/24" >/dev/null 2>&1 || true
  fi

  local ip
  while IFS= read -r ip; do
    [ -z "$ip" ] && continue

    local out
    if out="$(curl_json_with_auto_route "$iface" "$ip" "/api/wifi/status" 2>/dev/null)"; then
      if [[ "$out" == *'"mode"'* ]]; then
        echo "$ip"
        return 0
      fi
    fi
  done < <(
    while IFS= read -r line; do
      local arp_ip
      local arp_mac

      arp_ip="$(printf '%s' "$line" | sed -nE 's/.*\(([0-9.]+)\).*/\1/p')"
      arp_mac="$(printf '%s' "$line" | sed -nE 's/.* at ([0-9A-Fa-f:.-]+) .*/\1/p' | tr '[:upper:]' '[:lower:]' | tr '-' ':')"

      if [ -n "$arp_ip" ] && [ "$arp_mac" = "$target_mac" ]; then
        echo "$arp_ip"
      fi
    done < <(arp -an 2>/dev/null)
  )

  return 1
}

discover_home_host() {
  local iface="$1"

  if ! command -v fping >/dev/null 2>&1; then
    return 1
  fi

  local host
  while IFS= read -r host; do
    [ -z "$host" ] && continue
    [ "$host" = "$HOME_IP" ] && continue

    local out
    if out="$(curl_json_with_auto_route "$iface" "$host" "/api/wifi/status" 2>/dev/null)"; then
      if [[ "$out" == *'"mode"'* ]]; then
        echo "$host"
        return 0
      fi
    fi
  done < <(fping -a -q -g "${HOME_SUBNET_PREFIX}.0/24" 2>/dev/null || true)

  return 1
}

curl_json() {
  local iface="$1"
  local host="$2"
  local path="$3"

  if [ -n "$iface" ]; then
    curl -sS --interface "$iface" --max-time "$CURL_TIMEOUT_SEC" "http://${host}:8001${path}"
  else
    curl -sS --max-time "$CURL_TIMEOUT_SEC" "http://${host}:8001${path}"
  fi
}

curl_json_with_auto_route() {
  local iface="$1"
  local host="$2"
  local path="$3"

  local out
  if out="$(curl_json "$iface" "$host" "$path" 2>/dev/null)"; then
    echo "$out"
    return 0
  fi

  if [ -n "$iface" ]; then
    if out="$(curl_json "" "$host" "$path" 2>/dev/null)"; then
      echo "$out"
      return 0
    fi
  fi

  return 1
}

post_mode_switch() {
  local iface="$1"
  local host="$2"
  local mode="$3"

  local result
  if [ -n "$iface" ] && result="$(curl -sS --interface "$iface" --max-time 4 -X POST "http://${host}:8001/api/wifi/switch" \
    -H 'Content-Type: application/json' \
    -d "{\"mode\":\"${mode}\"}" 2>/dev/null)"; then
    log "switch request mode=${mode} host=${host} via_iface=${iface} response=${result}"
    return 0
  fi

  if [ -n "$iface" ]; then
    log "WARN: switch request via iface=${iface} failed, retry without interface host=${host}"
  fi

  if result="$(curl -sS --max-time 4 -X POST "http://${host}:8001/api/wifi/switch" \
    -H 'Content-Type: application/json' \
    -d "{\"mode\":\"${mode}\"}" 2>/dev/null)"; then
    log "switch request mode=${mode} host=${host} via_iface=auto response=${result}"
    return 0
  fi

  log "ERROR: switch request failed mode=${mode} host=${host}"
  return 1
}

wait_for_status() {
  local label="$1"
  local iface="$2"
  local timeout_sec="$3"
  shift 3

  WAIT_HOST=""
  local deadline=$((SECONDS + timeout_sec))

  while [ "$SECONDS" -lt "$deadline" ]; do
    for host in "$@"; do
      [ -z "$host" ] && continue
      local out
      if out="$(curl_json_with_auto_route "$iface" "$host" "/api/wifi/status" 2>/dev/null)"; then
        WAIT_HOST="$host"
        log "${label}: reachable host=${host} status=${out}"
        return 0
      fi
    done
    sleep "$STEP_WAIT_SEC"
  done

  log "${label}: timeout after ${timeout_sec}s"
  return 1
}

smoke_sensor_metering() {
  local iface="$1"
  local host="$2"

  local sensor
  local metering

  sensor="$(curl_json "$iface" "$host" "/api/sensor/status" || true)"
  metering="$(
    if [ -n "$iface" ]; then
      curl -sS --interface "$iface" --max-time "$CURL_TIMEOUT_SEC" -X POST "http://${host}:8001/api/metering" \
        -H 'Content-Type: application/json' -d '{}'
    else
      curl -sS --max-time "$CURL_TIMEOUT_SEC" -X POST "http://${host}:8001/api/metering" \
        -H 'Content-Type: application/json' -d '{}'
    fi
  )"

  log "sensor_status=${sensor}"
  log "metering=${metering}"
}

if ! [[ "$CYCLES" =~ ^[0-9]+$ ]] || [ "$CYCLES" -lt 1 ]; then
  echo "CYCLES must be an integer >= 1" >&2
  exit 1
fi

if [ -z "$AP_INTERFACE" ]; then
  AP_INTERFACE="$(detect_wifi_interface || true)"
fi
if [ -z "$HOME_INTERFACE" ]; then
  HOME_INTERFACE="$AP_INTERFACE"
fi

log "start wifi cycle test cycles=${CYCLES} ap_host=${AP_HOST} home_host=${HOME_HOST} home_ip=${HOME_IP}"
log "home_subnet_prefix=${HOME_SUBNET_PREFIX}"
log "home_mac=${HOME_MAC}"
log "interfaces ap='${AP_INTERFACE:-auto}' home='${HOME_INTERFACE:-auto}'"
warn_route_interface_mismatch "$HOME_IP" "$HOME_INTERFACE"

for cycle in $(seq 1 "$CYCLES"); do
  log "=== cycle ${cycle}/${CYCLES}: AP -> tethering -> AP ==="

  if wait_for_status "AP precheck" "$AP_INTERFACE" 10 "$AP_HOST"; then
    ap_active_host="$WAIT_HOST"
    log "precheck: AP side is reachable"
  elif wait_for_status "Home precheck" "$HOME_INTERFACE" 20 "$HOME_HOST" "$HOME_IP"; then
    home_active_host="$WAIT_HOST"
    log "precheck: Home side is reachable. Bootstrapping to AP first."
    post_mode_switch "$HOME_INTERFACE" "$home_active_host" "ap"
    if ! wait_for_status "AP bootstrap wait" "$AP_INTERFACE" "$AP_WAIT_SEC" "$AP_HOST"; then
      log "ERROR: AP bootstrap failed."
      exit 2
    fi
    ap_active_host="$WAIT_HOST"
  elif discovered_home_host="$(discover_home_host_by_mac "$HOME_INTERFACE")"; then
    home_active_host="$discovered_home_host"
    log "precheck: discovered Home endpoint by MAC host=${home_active_host}. Bootstrapping to AP first."
    post_mode_switch "$HOME_INTERFACE" "$home_active_host" "ap"
    if ! wait_for_status "AP bootstrap wait" "$AP_INTERFACE" "$AP_WAIT_SEC" "$AP_HOST"; then
      log "ERROR: AP bootstrap failed after MAC-based host discovery."
      exit 2
    fi
    ap_active_host="$WAIT_HOST"
  elif discovered_home_host="$(discover_home_host "$HOME_INTERFACE")"; then
    home_active_host="$discovered_home_host"
    log "precheck: discovered Home endpoint host=${home_active_host}. Bootstrapping to AP first."
    post_mode_switch "$HOME_INTERFACE" "$home_active_host" "ap"
    if ! wait_for_status "AP bootstrap wait" "$AP_INTERFACE" "$AP_WAIT_SEC" "$AP_HOST"; then
      log "ERROR: AP bootstrap failed after host discovery."
      exit 2
    fi
    ap_active_host="$WAIT_HOST"
  else
    log "ERROR: neither AP nor Home endpoint is reachable."
    exit 2
  fi

  post_mode_switch "$AP_INTERFACE" "$ap_active_host" "tethering"

  if ! wait_for_status "Home wait" "$HOME_INTERFACE" "$HOME_WAIT_SEC" "$HOME_HOST" "$HOME_IP"; then
    log "ERROR: tethering reachability failed."
    exit 3
  fi
  home_active_host="$WAIT_HOST"

  post_mode_switch "$HOME_INTERFACE" "$home_active_host" "ap"

  if ! wait_for_status "AP wait" "$AP_INTERFACE" "$AP_WAIT_SEC" "$AP_HOST"; then
    log "ERROR: AP reachability failed after tethering -> AP."
    exit 4
  fi
  ap_active_host="$WAIT_HOST"

  smoke_sensor_metering "$AP_INTERFACE" "$ap_active_host"

done

log "SUCCESS: wifi cycle test finished cycles=${CYCLES}"
