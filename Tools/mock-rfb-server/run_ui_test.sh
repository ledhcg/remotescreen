#!/bin/zsh
# Runs the UI tests for machine selection, sign-in, the session toolbar, observe mode, quality mode and the sidebar:
# mock RFB server + app in the simulator. Never touches a real Mac (the mock server listens on 127.0.0.1:5959 only).
#
# Three passes, each with its own server and log, so event-sequence assertions do not mix with other tests.
#
# Usage:  Tools/mock-rfb-server/run_ui_test.sh [simulator UDID] [screenshot directory]
set -euo pipefail
cd "$(dirname "$0")/../.."

UDID="${1:-$(xcrun simctl list devices available | grep -m1 'iPhone' | grep -oE '[0-9A-F-]{36}')}"
SHOTS="${2:-}"

# run_pass <UI test class>...: start the mock server, run the classes, stop the server. Sets LOG to the log path.
run_pass() {
  LOG="$(mktemp -d)/events.jsonl"
  python3 -I Tools/mock-rfb-server/server.py --port 5959 --log "$LOG" > /dev/null 2>&1 &
  local server=$!
  sleep 1.5
  local only=()
  for name in "$@"; do only+=("-only-testing:RemoteScreenAppUITests/$name"); done
  (cd App && xcodegen generate > /dev/null && env ${SHOTS:+TEST_RUNNER_SHOT_DIR="$SHOTS"} xcodebuild test \
    -project RemoteScreenApp.xcodeproj -scheme RemoteScreenApp \
    -destination "platform=iOS Simulator,id=$UDID" -derivedDataPath build \
    CODE_SIGNING_ALLOWED=NO "${only[@]}" 2>&1 | grep -E 'error:|failed|passed|TEST (SUCCEEDED|FAILED)') || true
  kill $server 2>/dev/null || true
  wait $server 2>/dev/null || true
}

# Pass 1: machine selection, sign-in, toolbar, observe mode, display mode.
run_pass ConnectionUITests SessionChromeUITests ObserveModeUITests DisplayModeUITests
# Observe mode must send nothing to the server (the tests only act; the assertion is here).
python3 -I Tools/mock-rfb-server/verify_observe.py "$LOG"

# Pass 2: quality mode. The server receives the expected pixel formats in order.
run_pass QualityUITests
python3 -I Tools/mock-rfb-server/verify_quality.py "$LOG"

# Pass 3: modifier-key sidebar. The server receives sticky/locked ⌘ around the clicks, ⌘Z and Escape, with no stuck keys.
run_pass SidebarUITests
python3 -I Tools/mock-rfb-server/verify_sidebar.py "$LOG"
