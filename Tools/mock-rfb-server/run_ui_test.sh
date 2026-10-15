#!/bin/zsh
# Chạy UI test của luồng chọn máy, đăng nhập, thanh công cụ phiên, chế độ chỉ xem, chế độ chất lượng và sidebar:
# server RFB giả + app trong simulator. Không đụng vào máy Mac thật nào (server giả chỉ nghe 127.0.0.1:5959).
#
# Ba lượt, mỗi lượt một server và một log riêng, để phần khẳng định chuỗi sự kiện không lẫn với bài khác.
#
# Dùng:  Tools/mock-rfb-server/run_ui_test.sh [UDID simulator] [thư mục lưu ảnh chụp]
set -euo pipefail
cd "$(dirname "$0")/../.."

UDID="${1:-$(xcrun simctl list devices available | grep -m1 'iPhone' | grep -oE '[0-9A-F-]{36}')}"
SHOTS="${2:-}"

# run_pass <tên log> <class UI test>...: bật server giả, chạy các class, tắt server. In đường dẫn log ra biến LOG.
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

# Lượt 1: chọn máy, đăng nhập, thanh công cụ, chỉ xem, chế độ hiển thị.
run_pass ConnectionUITests SessionChromeUITests ObserveModeUITests DisplayModeUITests
# Chế độ "Chỉ xem" thật sự không gửi gì lên server (bài test chỉ thao tác, phần khẳng định nằm ở đây).
python3 -I Tools/mock-rfb-server/verify_observe.py "$LOG"

# Lượt 2: chế độ chất lượng. Server nhận đúng định dạng pixel theo đúng thứ tự.
run_pass QualityUITests
python3 -I Tools/mock-rfb-server/verify_quality.py "$LOG"

# Lượt 3: sidebar phím bổ trợ. Server nhận ⌘ dính/khóa đúng quanh các cú nhấp, ⌘Z, Escape, không kẹt phím.
run_pass SidebarUITests
python3 -I Tools/mock-rfb-server/verify_sidebar.py "$LOG"
