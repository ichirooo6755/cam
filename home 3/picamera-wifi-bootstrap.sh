#!/usr/bin/env bash
# API サーバー（Python）が無くても、テザリング指定でなければ NetworkManager の Hotspot を起動する。
# デプロイ・メンテ用の SSH 経路（PiCamera AP）を確保する。
set -u

SETTINGS=/home/pi/camera_settings.json
NMCLI=/usr/bin/nmcli
if ! command -v nmcli >/dev/null 2>&1; then
  NMCLI=nmcli
fi

mode=ap
if [[ -f "$SETTINGS" ]]; then
  mode="$(python3 -c "import json; print(str(json.load(open('$SETTINGS')).get('wifi_mode') or 'ap'))")"
fi

if [[ "$mode" == "tethering" ]]; then
  exit 0
fi

if ! "$NMCLI" -t -f STATE general >/dev/null 2>&1; then
  echo "picamera-wifi-bootstrap: NetworkManager not ready, skip" >&2
  exit 0
fi

if "$NMCLI" connection show Hotspot &>/dev/null; then
  "$NMCLI" connection up Hotspot || true
else
  echo "picamera-wifi-bootstrap: Hotspot profile missing; create once via API or nmcli" >&2
fi
exit 0
