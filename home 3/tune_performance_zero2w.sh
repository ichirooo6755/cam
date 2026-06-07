#!/usr/bin/env bash
# Pi Zero 2 W 向けチューニング（ラッパー）
# カメラ設定は上書きしない — システム層のみ setup_zero2w_system.sh に委譲
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec bash "${SCRIPT_DIR}/setup_zero2w_system.sh" --full
