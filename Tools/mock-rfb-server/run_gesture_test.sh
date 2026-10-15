#!/bin/zsh
# Chụm/xoay gửi lên Mac (message 23): server giả --apple + app trong simulator. Không đụng Mac thật (server chỉ nghe 127.0.0.1).
# Dùng:  Tools/mock-rfb-server/run_gesture_test.sh [UDID simulator]
set -euo pipefail
cd "$(dirname "$0")/../.."

UDID="${1:-$(xcrun simctl list devices available | grep -m1 'iPhone' | grep -oE '[0-9A-F-]{36}')}"
LOG="$(mktemp -d)/events.jsonl"

python3 -I Tools/mock-rfb-server/server.py --port 5959 --apple --log "$LOG" > /dev/null 2>&1 &
SERVER_PID=$!
trap 'kill $SERVER_PID 2>/dev/null || true' EXIT
sleep 1.5

(cd App && xcodegen generate > /dev/null && xcodebuild test \
  -project RemoteScreenApp.xcodeproj -scheme RemoteScreenApp \
  -destination "platform=iOS Simulator,id=$UDID" -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO -only-testing:RemoteScreenAppUITests/AppleGestureUITests 2>&1 | grep -E 'error:|TEST (SUCCEEDED|FAILED)')

python3 -I Tools/mock-rfb-server/verify_gestures.py "$LOG"
