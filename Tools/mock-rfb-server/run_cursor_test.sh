#!/bin/zsh
# Kiểm tra con trỏ từ xa hiện đúng chỗ: server RFB giả + app trong simulator + XCUITest chụp màn hình + script đối chiếu ảnh.
# Không đụng vào máy Mac thật nào (server giả chỉ nghe 127.0.0.1:5959). Ảnh chụp bị xóa sau khi kiểm.
#
# Dùng:  Tools/mock-rfb-server/run_cursor_test.sh [UDID simulator]
set -euo pipefail
cd "$(dirname "$0")/../.."

UDID="${1:-$(xcrun simctl list devices available | grep -m1 'iPhone' | grep -oE '[0-9A-F-]{36}')}"
WORK="$(mktemp -d)"
SHOT="$WORK/cursor.png"

python3 -I Tools/mock-rfb-server/server.py --port 5959 --log "$WORK/events.jsonl" > /dev/null 2>&1 &
SERVER_PID=$!
trap 'kill $SERVER_PID 2>/dev/null || true; rm -rf "$WORK"' EXIT
sleep 1.5

(cd App && xcodegen generate > /dev/null && TEST_RUNNER_CURSOR_SHOT="$SHOT" xcodebuild test \
  -project RemoteScreenApp.xcodeproj -scheme RemoteScreenApp \
  -destination "platform=iOS Simulator,id=$UDID" -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO -only-testing:RemoteScreenAppUITests/CursorUITests 2>&1 | grep -E 'error:|TEST (SUCCEEDED|FAILED)')

python3 -I Tools/mock-rfb-server/verify_cursor.py "$SHOT"
