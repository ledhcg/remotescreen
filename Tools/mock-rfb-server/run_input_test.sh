#!/bin/zsh
# Runs the end-to-end input test: mock RFB server + app in the simulator + XCUITest + log check.
# Never touches a real Mac (the mock server listens on 127.0.0.1:5959 only).
#
# Usage:  Tools/mock-rfb-server/run_input_test.sh [simulator UDID]
set -euo pipefail
cd "$(dirname "$0")/../.."

UDID="${1:-$(xcrun simctl list devices available | grep -m1 'iPhone' | grep -oE '[0-9A-F-]{36}')}"
LOG="$(mktemp -d)/events.jsonl"

python3 -I Tools/mock-rfb-server/server.py --port 5959 --log "$LOG" > /dev/null 2>&1 &
SERVER_PID=$!
trap 'kill $SERVER_PID 2>/dev/null || true' EXIT
sleep 1.5

(cd App && xcodegen generate > /dev/null && xcodebuild test \
  -project ScreonApp.xcodeproj -scheme ScreonApp \
  -destination "platform=iOS Simulator,id=$UDID" -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO -only-testing:ScreonAppUITests/InputUITests 2>&1 | grep -E 'error:|TEST (SUCCEEDED|FAILED)')

python3 -I Tools/mock-rfb-server/verify_input.py "$LOG"
