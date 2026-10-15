#!/bin/zsh
# Chạy kiểm thử nhập liệu đầu-cuối: server RFB giả + app trong simulator + XCUITest + đối chiếu log.
# Không đụng vào máy Mac thật nào (server giả chỉ nghe 127.0.0.1:5959).
#
# Dùng:  Tools/mock-rfb-server/run_input_test.sh [UDID simulator]
set -euo pipefail
cd "$(dirname "$0")/../.."

UDID="${1:-$(xcrun simctl list devices available | grep -m1 'iPhone' | grep -oE '[0-9A-F-]{36}')}"
LOG="$(mktemp -d)/events.jsonl"

python3 -I Tools/mock-rfb-server/server.py --port 5959 --log "$LOG" > /dev/null 2>&1 &
SERVER_PID=$!
trap 'kill $SERVER_PID 2>/dev/null || true' EXIT
sleep 1.5

(cd App && xcodegen generate > /dev/null && xcodebuild test \
  -project RemoteScreenApp.xcodeproj -scheme RemoteScreenApp \
  -destination "platform=iOS Simulator,id=$UDID" -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO -only-testing:RemoteScreenAppUITests/InputUITests 2>&1 | grep -E 'error:|TEST (SUCCEEDED|FAILED)')

python3 -I Tools/mock-rfb-server/verify_input.py "$LOG"
