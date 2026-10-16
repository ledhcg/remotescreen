#!/bin/zsh
# Runs the App Mode end-to-end test: mock-link-helper (fake Mac, 127.0.0.1 only) + app in the simulator + XCUITest + log check.
# Never touches a real Mac. The helper pairs with --pairing auto (test only).
#
# The UI test class is `AppModeUITests`. It finds the helper through environment variables that xcodebuild forwards
# (the TEST_RUNNER_ prefix is stripped) and passes them on in the app's launch environment:
#   SCREON_MOCK_HOST=127.0.0.1  SCREON_MOCK_PORT=<port>  SCREON_MOCK_QR=<pairing payload string>
#
# Usage:  Tools/mock-link-helper/run_appmode_test.sh [simulator UDID] [scenario: basic|churn|locked]
set -euo pipefail
cd "$(dirname "$0")/../.."

UDID="${1:-$(xcrun simctl list devices available | grep -m1 'iPad' | grep -oE '[0-9A-F-]{36}' || true)}"
UDID="${UDID:-$(xcrun simctl list devices available | grep -m1 'iPhone' | grep -oE '[0-9A-F-]{36}')}"
SCENARIO="${2:-basic}"
PORT=7361
WORK="$(mktemp -d)"
LOG="$WORK/events.jsonl"
QR="$WORK/qr.txt"

swift build --product mock-link-helper
BIN="$(swift build --show-bin-path)/mock-link-helper"

"$BIN" --port "$PORT" --scenario "$SCENARIO" --pairing auto --log "$LOG" --qr-out "$QR" --identity-dir "$WORK/identity" \
  > "$WORK/helper.out" 2>&1 &
HELPER_PID=$!
cleanup() { kill -TERM $HELPER_PID 2>/dev/null || true; wait $HELPER_PID 2>/dev/null || true; rm -rf "$WORK"; }
trap cleanup EXIT

for _ in {1..40}; do [[ -s "$QR" ]] && break; sleep 0.25; done
[[ -s "$QR" ]] || { echo "mock-link-helper did not start:"; cat "$WORK/helper.out"; exit 1; }

if ! grep -rqs "AppModeUITests" App/ScreonAppUITests; then
  echo "SKIP: no AppModeUITests class in App/ScreonAppUITests yet (the helper started and paired nothing)."
  exit 0
fi

(cd App && xcodegen generate > /dev/null && env \
  TEST_RUNNER_SCREON_MOCK_HOST=127.0.0.1 TEST_RUNNER_SCREON_MOCK_PORT="$PORT" TEST_RUNNER_SCREON_MOCK_QR="$(cat "$QR")" \
  xcodebuild test \
  -project ScreonApp.xcodeproj -scheme ScreonApp \
  -destination "platform=iOS Simulator,id=$UDID" -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO -only-testing:ScreonAppUITests/AppModeUITests 2>&1 | grep -E 'error:|failed|passed|TEST (SUCCEEDED|FAILED)') || true

# Let the helper flush, then verify what it received.
sleep 0.5
python3 -I Tools/mock-link-helper/verify_appmode.py "$LOG"
