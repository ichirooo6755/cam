#!/bin/bash
set -euo pipefail

PROJECT="PiCameraControl.xcodeproj"
SCHEME="PiCameraControl"
CONFIG="Debug"

pick_simulator_id() {
  /usr/bin/python3 - <<'PY'
import json
import subprocess

result = subprocess.run(
    ["xcrun", "simctl", "list", "devices", "available", "-j"],
    capture_output=True,
    text=True,
    check=True,
)
data = json.loads(result.stdout)
devices = data.get("devices", {})
for runtimes in devices.values():
    for device in runtimes:
        if device.get("isAvailable"):
            print(device.get("udid"))
            raise SystemExit(0)
raise SystemExit(1)
PY
}

SIM_ID=$(pick_simulator_id)
if [[ -z "${SIM_ID}" ]]; then
  echo "No available iOS Simulator devices found."
  exit 1
fi

echo "Building with simulator id: ${SIM_ID}"
xcodebuild -project "${PROJECT}" -scheme "${SCHEME}" -configuration "${CONFIG}" \
  -destination "platform=iOS Simulator,id=${SIM_ID}" build
