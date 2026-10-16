#!/bin/zsh
# Runs the App Mode end-to-end test: mock-link-helper (fake Mac, 127.0.0.1 only) + app in the simulator + XCUITest + log check.
# Never touches a real Mac. The helper pairs with --pairing auto (test only).
#
# The UI test class is `AppModeUITests`. It finds the helper through environment variables that xcodebuild forwards
# (the TEST_RUNNER_ prefix is stripped) and passes them on in the app's launch environment:
#   SCREON_MOCK_HOST=127.0.0.1  SCREON_MOCK_PORT=<port>  SCREON_MOCK_QR=<pairing payload string>
#
# The app is signed ad hoc (no team): the link identity lives in the Keychain, which an unsigned simulator build cannot use.
# App Mode needs iPadOS 26 or later: without an argument the script picks an available iPad whose runtime is iOS 26+.
#
# Usage:  Tools/mock-link-helper/run_appmode_test.sh [simulator UDID] [scenario: basic|churn|locked]
set -euo pipefail
cd "$(dirname "$0")/../.."

pick_ipad() {
  xcrun simctl list devices available -j | python3 -I -c '
import json, re, sys
data = json.load(sys.stdin)["devices"]
best = None
for runtime, devices in data.items():
    m = re.search(r"iOS-(\d+)", runtime)
    if not m or int(m.group(1)) < 26:
        continue
    for d in devices:
        if "iPad" in d["name"] and d.get("isAvailable", True):
            key = (int(m.group(1)), d["state"] == "Booted")
            if best is None or key > best[0]:
                best = (key, d["udid"])
print(best[1] if best else "")
'
}

UDID="${1:-$(pick_ipad)}"
[[ -n "$UDID" ]] || { echo "No available iPad simulator with iOS 26 or later."; exit 1; }
SCENARIO="${2:-basic}"
PORT="${SCREON_MOCK_PORT:-7361}"
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

echo "Simulator: $UDID"
xcrun simctl boot "$UDID" 2>/dev/null || true
# A fresh app: no earlier pairing or saved computer, so the test pairs with this run's helper identity.
xcrun simctl uninstall "$UDID" com.ledinhcuong.screon 2>/dev/null || true

(cd App && xcodegen generate > /dev/null)
TEST_LOG="$WORK/xcodebuild.log"
set +e
(cd App && env \
  TEST_RUNNER_SCREON_MOCK_HOST=127.0.0.1 TEST_RUNNER_SCREON_MOCK_PORT="$PORT" TEST_RUNNER_SCREON_MOCK_QR="$(cat "$QR")" \
  xcodebuild test \
  -project ScreonApp.xcodeproj -scheme ScreonApp \
  -destination "platform=iOS Simulator,id=$UDID" -derivedDataPath build \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=NO -only-testing:ScreonAppUITests/AppModeUITests > "$TEST_LOG" 2>&1)
TEST_STATUS=$?
set -e
grep -E 'error:|Test Case .* (passed|failed)|TEST (SUCCEEDED|FAILED)' "$TEST_LOG" | sed 's/^/  /' || true
if [[ $TEST_STATUS -ne 0 ]]; then
  echo "UI test failed (xcodebuild exit $TEST_STATUS). Last lines:"
  tail -40 "$TEST_LOG"
  exit 1
fi

# Let the helper flush, then verify what it received.
sleep 0.5
[[ -z "${SCREON_KEEP_LOG:-}" ]] || cp "$LOG" "$SCREON_KEEP_LOG"
# The UI test must run over QUIC (the default transport); set SCREON_EXPECT_TRANSPORT=tcp when forcing TCP.
SCREON_EXPECT_TRANSPORT="${SCREON_EXPECT_TRANSPORT:-quic}" python3 -I Tools/mock-link-helper/verify_appmode.py "$LOG"
