#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

mkdir -p .codex-home .swiftpm-cache .swift-module-cache .clang-module-cache

echo "[1/4] Swift package tests"
HOME="$ROOT/.codex-home" \
SWIFT_MODULECACHE_PATH="$ROOT/.swift-module-cache" \
CLANG_MODULE_CACHE_PATH="$ROOT/.clang-module-cache" \
swift test --disable-sandbox --scratch-path .build --cache-path .swiftpm-cache

echo "[2/4] Python parser tests"
python3 tests/run_unit_tests.py

echo "[3/4] Live subscription check"
if [[ -n "${SUBSCRIPTION_URLS:-}" ]]; then
  python3 scripts/live_subscription_check.py
else
  echo "Skip live check (set SUBSCRIPTION_URLS to enable)"
fi

echo "[4/4] Build smoke"
APP="$ROOT/dist/BACK_TO_USSR.app"
"$ROOT/build_back_to_ussr_app.command" >/dev/null
test -x "$APP/Contents/MacOS/BACK_TO_USSR"
test -x "$APP/Contents/Resources/sing-box"
test -f "$ROOT/dist/BACK_TO_USSR.app.zip"
test -f "$ROOT/dist/BACK_TO_USSR.dmg"
file "$APP/Contents/MacOS/BACK_TO_USSR"
file "$APP/Contents/Resources/sing-box"
file "$ROOT/dist/BACK_TO_USSR.dmg"

echo "All checks done"
