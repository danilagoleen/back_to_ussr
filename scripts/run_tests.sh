#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "[1/3] Unit tests"
python3 tests/run_unit_tests.py

echo "[2/3] Live subscription check"
python3 scripts/live_subscription_check.py

echo "[3/3] Build smoke"
APP="$ROOT/dist/BACK_TO_USSR.app"
if [[ -d "$APP" ]]; then
  file "$APP/Contents/MacOS/BACK_TO_USSR"
else
  echo "No built app yet: $APP"
fi

echo "All checks done"
