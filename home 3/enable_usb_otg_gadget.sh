#!/usr/bin/env bash
# Pi Zero / Zero 2 W: USB OTG (dwc2) + optional g_ether in cmdline.txt
# Run ON the Raspberry Pi (needs sudo for /boot/firmware).
set -euo pipefail

usage() {
  echo "Usage: sudo $0 [--config-only | --ether]"
  echo "  --config-only  Add dtoverlay=dwc2 to config.txt only"
  echo "  --ether        Also append modules-load=dwc2,g_ether to cmdline.txt (once)"
  exit 1
}

if [[ "${EUID:-}" -ne 0 ]]; then
  echo "Run with sudo on the Pi, e.g.: sudo bash $0 --ether"
  exit 1
fi

MODE="ether"
case "${1:-}" in
  --config-only) MODE="config" ;;
  --ether)       MODE="ether" ;;
  -h|--help|"")  usage ;;
  *)             usage ;;
esac

if [[ -f /boot/firmware/config.txt ]]; then
  BOOT="/boot/firmware"
elif [[ -f /boot/config.txt ]]; then
  BOOT="/boot"
else
  echo "Neither /boot/firmware/config.txt nor /boot/config.txt found."
  exit 1
fi

CONFIG="${BOOT}/config.txt"
CMDLINE="${BOOT}/cmdline.txt"
TS="$(date +%Y%m%d%H%M%S)"

backup() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  cp -a "$f" "${f}.bak.${TS}"
  echo "Backed up: ${f}.bak.${TS}"
}

backup "$CONFIG"
if [[ ! -f "$CMDLINE" ]]; then
  echo "Missing: $CMDLINE"
  exit 1
fi
backup "$CMDLINE"

if grep -qE '^[[:space:]]*dtoverlay=dwc2([[:space:]]|$)' "$CONFIG" \
  || grep -qE '^[[:space:]]*dtoverlay=dwc2,' "$CONFIG"; then
  echo "config.txt: dtoverlay=dwc2 already present"
else
  printf '\n# USB OTG (dwc2) — added by enable_usb_otg_gadget.sh\ndtoverlay=dwc2\n' >> "$CONFIG"
  echo "config.txt: appended dtoverlay=dwc2"
fi

if [[ "$MODE" == "config" ]]; then
  echo "Done (--config-only). Reboot to apply: sudo reboot"
  exit 0
fi

# Single-line cmdline.txt: append modules-load once
LINE="$(tr -d '\n' < "$CMDLINE" | sed 's/[[:space:]]*$//')"
if echo "$LINE" | grep -q 'modules-load=dwc2,g_ether'; then
  echo "cmdline.txt: modules-load=dwc2,g_ether already present"
else
  # Remove duplicate dwc2-only load if we're upgrading to g_ether
  LINE="$(echo "$LINE" | sed -E 's/[[:space:]]+modules-load=dwc2([[:space:]]|$)/ /g')"
  printf '%s modules-load=dwc2,g_ether\n' "$LINE" > "$CMDLINE"
  echo "cmdline.txt: appended modules-load=dwc2,g_ether"
fi

echo "Reboot required: sudo reboot"
