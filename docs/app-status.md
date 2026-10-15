# Trạng thái app iPhone/iPad

Cập nhật: 2026-10-14. Tên app là **tạm thời**, chưa chốt. Bundle id hiện là `com.ledinhcuong.remotescreen` và có thể đổi sau.

## Kiến trúc

```
Sources/
  RFBCrypto/      DES, AES-ECB, MD5, số lớn 4096-bit (Montgomery), số ngẫu nhiên
  RFBKit/         giao thức RFB: handshake, xác thực (None, VNC, ARD), Raw/CopyRect/ZRLE, Cursor, phiên, hàng đợi gửi
  RemoteDisplay/  hình học khung nhìn, bộ vẽ Metal (chạy được trên macOS để test), RemoteScreenView (UIKit)
  InputKit/       bàn phím → keysym X11, cử chỉ chạm → sự kiện chuột, phím ảo và phím bổ trợ dính (thuần logic, không UIKit)
  SessionKit/     chính sách kết nối lại (ReconnectPolicy), đồng bộ clipboard (ClipboardBridge, thuần logic, bảng clipboard trừu tượng)
  ConnectionKit/  máy đã lưu (JSON ghi nguyên tử), kho mật khẩu (giao diện; Keychain nằm trong app), kiểm tra form, tìm máy bằng Bonjour
Tools/
  rfbprobe/            công cụ dòng lệnh chẩn đoán giao thức (không dùng trong app)
  replay-check/        bộ giải mã/mã hóa ZRLE độc lập bằng Python để đối chiếu
  mock-rfb-server/     server RFB giả + script kiểm thử nhập liệu đầu-cuối
App/
  project.yml          nguồn sự thật của dự án Xcode (XcodeGen). File .xcodeproj được sinh ra, không commit.
  RemoteScreenApp/     SwiftUI: màn hình kết nối, màn hình xem, SessionController
  RemoteScreenAppUITests/  XCUITest nhập liệu
```

## Cách chạy

| Việc | Lệnh |
|---|---|
| Toàn bộ test của gói (macOS) | `swift test` |
| Dự án Xcode | `cd App && xcodegen generate` |
| Build cho simulator | `xcodebuild -project App/RemoteScreenApp.xcodeproj -scheme RemoteScreenApp -destination 'platform=iOS Simulator,id=<UDID>' -derivedDataPath App/build CODE_SIGNING_ALLOWED=NO build` |
| Kiểm thử nhập liệu đầu-cuối (không đụng máy thật) | `Tools/mock-rfb-server/run_input_test.sh <UDID>` |
| UI test chọn máy, đăng nhập, thanh công cụ, chỉ xem, chế độ hiển thị, chất lượng (server giả; tham số 2 là thư mục lưu ảnh chụp simulator) | `Tools/mock-rfb-server/run_ui_test.sh <UDID> [thư mục ảnh]` |
| Bàn phím cứng đầu-cuối trên simulator (server giả) | `Tools/mock-rfb-server/run_keyboard_test.sh <UDID>` (chạy cả iPhone lẫn iPad) |
| Chạy thử với Mac thật trên simulator | `SIMCTL_CHILD_RFB_HOST=127.0.0.1 SIMCTL_CHILD_RFB_USER=<tài khoản> SIMCTL_CHILD_RFB_PASSWORD=<mật khẩu> xcrun simctl launch <UDID> com.ledinhcuong.remotescreen` (chỉ bản DEBUG) |

## Chạy trên iPhone/iPad thật

Cần team Apple Developer để ký. Thông tin ký của máy này nằm trong `App/Signing.local.xcconfig` (không commit), ví dụ:

```
DEVELOPMENT_TEAM = <TEAM_ID>
CODE_SIGN_STYLE = Automatic
```

```sh
cd App && xcodegen generate
xcodebuild -project RemoteScreenApp.xcodeproj -scheme RemoteScreenApp \
  -destination 'platform=iOS,id=<UDID thiết bị>' -derivedDataPath build -allowProvisioningUpdates build
xcrun devicectl device install app --device <UDID thiết bị> build/Build/Products/Debug-iphoneos/RemoteScreenApp.app
```

Điện thoại phải **mở khóa** thì `devicectl device process launch` mới mở được app. Lần đầu có thể cần tin cậy chứng chỉ:
Cài đặt > Cài đặt chung > VPN & Quản lý thiết bị.

Trạng thái (2026-10-14): đã **build, ký, cài và chạy** trên iPad Air 4 (iPad13,1, iPadOS 27.0.1); đã kết nối được tới Mac thật (do người dùng thử). iPhone 12 Pro Max đã cài nhưng chưa mở được vì máy khóa lúc cài.

Lần thử đầu trên iPad báo `NWError 50` (`ENETDOWN`, "Network is down"). Đã sửa hai việc: (1) `NWByteStream.connect(waitingPatience:)` không còn coi `.waiting` là lỗi chí mạng với các lỗi hệ thống có thể tự gỡ (50, 51, 65, DNS PolicyDenied của quyền Mạng cục bộ), mà chờ tối đa 20 giây, vì iOS giữ kết nối ở `.waiting` trong lúc hộp thoại xin quyền hiện ra. `ECONNREFUSED` cũng đi qua `.waiting` trên macOS (đo được: mất 21 giây nếu chờ nhầm), nên vẫn báo ngay. (2) `SessionController.describe` nói rõ việc cần làm cho từng mã lỗi mạng. **Nguyên nhân thật của lỗi 50 trên iPad chưa xác nhận**: có thể là quyền Mạng cục bộ chưa cấp hoặc Wi-Fi iPad tắt/khác mạng.

## Đã kiểm chứng

| Hạng mục | Bằng chứng |
|---|---|
| Hiển thị đúng nội dung, màu, vị trí | App trong simulator nối tới server giả có ảnh kiểm tra biết trước: 4 góc đúng từng giá trị màu, viền letterbox đen |
| Hiển thị màn hình Mac thật, cập nhật liên tục | App trong simulator nối tới `screensharingd` thật, thấy nội dung thay đổi giữa các lần chụp |
| GPU vẽ khớp phép đổi tọa độ trên CPU | Test Metal thật đọc ngược pixel (`FramebufferRendererTests`), kể cả khi phóng và kéo |
| Chạm một ngón, chạm đúp, chạm hai ngón (nhấp phải), nhấn giữ rồi kéo | XCUITest + server giả: 13 kiểm tra khớp |
| Bàn phím ảo (`A`, `b`, Return), không kẹt phím | Như trên |
| Hàng đợi gửi giữ đúng thứ tự (nhấn trước nhả) | 4 test, 200 cặp sự kiện |
| **iPad thật**: chạm một ngón đúng toạ độ | Server giả nhận (201,220), (599,449), (300,399) cho mục tiêu (200,220), (600,450), (300,400): lệch ≤ 1 pixel Mac |
| **iPad thật**: chạm đúp, nhấn giữ rồi kéo | Hai nhấp cách nhau 106 ms tại cùng điểm; nhấn nút trái sau 0,36 s giữ, di chuyển khi giữ nút, thả đúng chỗ |
| **iPad thật**: con trỏ từ xa vẽ đúng chỗ | Ảnh chụp: mũi tên trùng ô đánh dấu của server giả. Trên simulator: `run_cursor_test.sh`, lệch ≤ 1 pixel ảnh. GPU: `CursorRenderingTests`, đã thử đột biến |
| **iPad thật**: nút thanh công cụ, không nhấp xuyên xuống Mac | Log `toggleKeyboard`/`toggleActualSize` có gọi; server giả không nhận chuột từ cú bấm nút |
| **iPad thật**: bàn phím cứng (chữ, Shift+chữ, mũi tên, Ctrl+chữ, Option+chữ) | Server giả nhận đúng keysym và thứ tự nhấn/nhả |
| **iPad thật**: lưu máy, bền vững qua khởi động lại, mật khẩu lấy lại từ **Keychain thật**, xóa | Mục "Máy đã lưu" hiện sau khi nối; mở lại app vẫn còn; chạm vào là nối thẳng (không hỏi mật khẩu); vuốt rồi Xóa thì mục biến mất |
| **iPad thật**: tìm máy bằng Bonjour | Mục "Máy trong mạng" hiện đúng tên máy Mac trong mạng; chọn thì form đổi sang "Đã chọn" |
| Bonjour thật trên macOS | `ServiceBrowserLiveTests`: dịch vụ quảng bá trong tiến trình test được tìm ra, biến mất khi tắt, và nối được qua điểm cuối `.service` |
| Keychain thật | `RemoteScreenAppTests` trên simulator (cần ký, không chạy được với `CODE_SIGNING_ALLOWED=NO`: lỗi -34018); đã thử đột biến |
| Clipboard Apple (loại 11 hỏi, loại 31 đáp/gửi): giải mã payload **thật** của server, mã hóa, dữ liệu hỏng/độc hại | `ClipboardTests` (35 test) dùng payload thật 264 byte + payload do zlib Python tạo; mã hóa lại ra đúng từng byte; thử đột biến |
| Clipboard Apple với **Mac thật** (`rfbprobe`) | Hỏi clipboard Mac nhận lại tiếng Việt nguyên vẹn; gửi `Xin chào Việt Nam đệ ố ữ 🙂` lên Mac thì `pbpaste` ra đúng chuỗi |
| **iPad thật → Mac thật**: nút Lấy từ Mac | Thông báo "Đã chép 32 ký tự từ Mac." đúng độ dài chuỗi tiếng Việt đã đặt |
| **iPad thật → Mac thật**: ⌘V đẩy clipboard iPad lên Mac | `changeCount` clipboard Mac tăng 236→237 sau khi cho phép dán (nội dung không phân biệt được với clipboard Mac vì Device Hub đồng bộ clipboard Mac sang iPad) |
| **iPad thật + server chuẩn (giả)**: Mac→iPad (`ServerCutText`) và iPad→Mac (⌘V ra `ClientCutText` đứng TRƯỚC phím v) | Log server giả: `cut_text "mock-clip-1 café"` xuất hiện giữa `Meta_L` nhấn và `v` nhấn |
| **iPad thật**: tự kết nối lại | Tắt server giả giữa phiên: biểu ngữ "Đang nối lại (3/6)", mở lại server thì app tự nối sau ~3 s, đúng lịch giãn cách |
| `ReconnectPolicy`, `ClipboardBridge`, `ClipboardShortcutDetector` | 8 + 26 + 11 test, đã thử đột biến từng chỗ then chốt |
| **iPad thật**: thanh phím phụ, phím bổ trợ dính | ⌘ rồi `c` ra Meta↓ c↓ c↑ Meta↑; ⌃ rồi ← ra Ctrl↓ Left↓ Left↑ Ctrl↑; esc ra Escape↓↑ |
| **Màn hình chọn máy kiểu Screen Sharing**: ô địa chỉ, máy đã lưu (chấm xanh khi Bonjour thấy), máy trong mạng, hộp thoại tên + mật khẩu, lỗi hiện ngay trong hộp thoại | `ConnectionUITests` + `SessionChromeUITests` (11 bài, iPhone và iPad simulator); `ComputerListTests` (8), `ConnectionFailureMessageTests` (8). Đã xem ảnh chụp cả hai cỡ. **iPad thật**: danh sách hiện đúng với "Mac mini" đã lưu và chấm xanh |
| Lỗi "để trống tên tài khoản" (người dùng đã gặp) có thông báo đúng việc cần làm | `blankUsernameIsCalledOutBecauseMacsNeedAnAccountName`: không còn đổ lỗi "sai tên" khi chưa nhập tên |
| **Chế độ "Chỉ xem"** thật sự không gửi gì lên Mac | `ObserveModeUITests` + `verify_observe.py`: chạm, chạm đúp, kéo, hai ngón lúc chỉ xem = 0 sự kiện; chạm lúc điều khiển = đúng 3. Đã thử đột biến: bỏ lớp chặn thì 41 sự kiện lọt và bài báo SAI |
| **iPad thật**: giữ phím thì lặp | Giữ mũi tên phải 2 s: nhấn lúc 0 s, lặp từ 0,41 s, khoảng 65 ms một lần (24 lần), đúng một lần nhả lúc nhả phím. Trước khi sửa: một nhấn, một nhả, không lặp. 10 test `KeyRepeatTests` |
| **iPad thật**: Home, End, Return, Backspace, Tab, mũi tên, F5, ⌘+chữ (Meta_L), Control+chữ, Option+chữ, Shift+chữ | Server giả nhận đúng keysym và thứ tự nhấn/nhả. Console của iPad xác nhận Home (HID 0x4A) và End (0x4D) tới `pressesBegan` |
| iPadOS giữ lại ⌘F, ta nhận lại bằng `UIKeyCommand` ưu tiên | Trên simulator iPad: trước khi sửa `Command+F: không tới server`, sau khi sửa khớp. Các ⌘+chữ khác (Z, S, O, P, T, N, W) tới bình thường |
| Thời gian số lớn ở bản debug | 49 ms (modexp 512-bit số mũ), nhờ cờ `-O` riêng cho `RFBCrypto` |

## Hiệu năng luồng hình (đo ngày 2026-10-14)

Triệu chứng người dùng báo: "kết nối và streaming bị lag". Nguyên nhân và cách đo:

| Phát hiện | Số liệu |
|---|---|
| **Bản Debug (`-Onone`) giải mã ZRLE chậm gấp 63 lần.** Bản cài bằng Xcode mặc định là Debug, nên iPad chỉ được 1-2 khung/giây | Cùng đoạn luồng thật 2560x1440 (362 cập nhật, 188 MiB): Release 11 ms/cập nhật, Debug 702 ms/cập nhật |
| Sửa: bật `-O` cho `RFBKit` và `RemoteDisplay` ngay cả ở Debug (`Package.swift`) | Debug còn 13 ms/cập nhật |
| Viết lại `decodeTile` bằng con trỏ có kiểm tra biên tường minh, ghi thẳng vào framebuffer; giải nén zlib vào bộ đệm dùng lại | Release 10,7 ms → 4,1 ms/cập nhật (2,6 lần). Khung hình cuối **giống hệt** bộ giải mã cũ (băm FNV-1a `59e83c05109f5bdd`) sau 362 cập nhật thật. Bài fuzz `ZRLEFuzzTests` xác nhận không ghi ra ngoài hình chữ nhật; đã đột biến hai phép kiểm biên và bài fuzz bắt được cả hai |
| Controller giữ `latestFrame` làm mỗi cập nhật sau buộc session sao chép nguyên bộ đệm (14,7 MB) dù chỉ đổi vài pixel | Đã bỏ; view tạo muộn lấy khung từ session |
| Xin cập nhật kế tiếp **sau** khi giải mã xong, nên server chờ | `pipelinesUpdateRequests`: xin ngay khi nhận tiêu đề cập nhật (xin lại bằng cỡ mới nếu server đổi cỡ). 6 test `SessionPipeliningTests` |
| **iPad thật (A14), Mac thật, bản Debug sau sửa** | 24-33 khung/s, 12-18 Mbit/s, giải mã 1,5-2,3 ms, vẽ 0,6-0,9 ms mỗi cập nhật (cửa sổ đầu tiên là khung đầy đủ: 43 ms) |
| **Luồng nặng đo được từ chính Mac**: hình nền là video `.mov` 4K (Aerial), nên khi màn hình hiện hình nền, server gửi gần cả màn hình mỗi khung | Một lần ghi 20 s: 361 cập nhật, 192 MiB (khoảng 77 Mbit/s), trung bình 2,5 triệu pixel mỗi cập nhật. Đổi sang hình nền tĩnh sẽ giảm mạnh. Mình không tự đổi cài đặt của bạn |

Cách đo lại:
- **Đoạn ghi thật rồi phát lại (chỉ đọc, không gửi chuột phím)**: `RFB_USER=<tài khoản> RFB_PASSWORD=<mật khẩu> .build/release/rfbprobe --login 30 --watch 20 --record <file> 127.0.0.1`, rồi `.build/release/rfbprobe --replay <file> --size 2560x1440` (in thời gian mỗi cập nhật và băm khung cuối). Đoạn ghi chứa hình màn hình thật: **xóa sau khi dùng, không commit**.
- **Trên thiết bị**: menu "…" › "Hiện thống kê luồng hình" (khung/s, Mbit/s, ms giải mã, ms vẽ). Bản Debug còn in dòng `RS_STATS` ra console (`devicectl device process launch --console ... --environment-variables '{"RFB_STATS":"1"}'`).
- Muốn tốc độ tối đa khi cài: build `-configuration Release`.

## Chất lượng hình: Tự động / Hiển thị tốt nhất / Hiệu năng tốt nhất

Menu "…" › "Chất lượng hình", lưu giữa các lần mở app (`UserDefaults`, khóa `qualityMode`). Chỉ có **hai núm thật** với server Apple (xem bên dưới), nên ba chế độ là:

| Chế độ | Màu | Trần khung hình | Ghi chú |
|---|---|---|---|
| **Tự động** (mặc định) | 32 bit | `nil` → 30 → 20 → 12 theo tải (`AdaptiveGovernor`) | Hạ sau 3 giây nặng liên tiếp (≥ 30 Mbit/s hoặc CPU ≥ 45%), nâng sau 15 giây nhẹ (≤ 10 Mbit/s và CPU ≤ 15%), mỗi lần một bậc |
| **Hiển thị tốt nhất** | 32 bit | không giới hạn | Không mất màu, nhanh nhất có thể |
| **Hiệu năng tốt nhất** | 16 bit (RGB565) | 20 khung/s | Ít byte nhất |

Độ sâu màu **không đổi được giữa phiên**: RFB không có dấu hiệu nào cho biết cập nhật đang bay dùng định dạng nào, nên đổi sang/khỏi "Hiệu năng tốt nhất" thì app nối lại ngắn (~1 giây, màn hình cuối vẫn hiện, banner "Đang áp dụng chế độ chất lượng mới…"). Đổi giữa hai chế độ cùng 32 bit thì chỉ đổi nhịp khung hình, không nối lại.

| Phát hiện / kết quả | Bằng chứng |
|---|---|
| **Server Apple không hỗ trợ Tight/JPEG, Hextile, RRE** (tự rơi về ZRLE hoặc Raw), **không nhận 8 bit** (đóng kết nối). Hỗ trợ ZRLE, Zlib, Raw, CopyRect, và **16 bit RGB565** | `rfbprobe --login 30 --probe-encodings`: Tight → trả ZRLE; Hextile, RRE → Raw; Raw 16 bit → đúng nửa dung lượng (7200 KiB so với 14400 KiB); 8 bit → `connectionClosed` |
| 16 bit dùng ít byte hơn | Hai kết nối song song, 15 giây, cùng nội dung, hai lần: **71% và 65%** số byte của 32 bit. Khung đầy đủ: **51%** (372 so với 725 KiB) |
| 16 bit hiển thị đúng trên server thật | `rfbprobe --check-depth-image` (ba kết nối song song, ba lần): 99,4-99,99% pixel nằm trong ±8 so với 32 bit, không kém độ trôi nội dung giữa hai khung 32 bit (A so B: 99,5-99,99%) |
| Giải mã 16 bit không chậm hơn | Phát lại luồng thật, Release: 32 bit 832 triệu pixel/s, 16 bit 922 triệu pixel/s; viết lại generic không làm chậm đường 32 bit (792 → 832) |
| **iPad thật + Mac thật**, bản Debug, cùng điều kiện | Hiển thị tốt nhất: ~25 khung/s, ~22 Mbit/s, giải mã 2,8 ms. Hiệu năng tốt nhất: ~17 khung/s, ~8 Mbit/s (ít hơn 2,7 lần), giải mã 3,9 ms, đúng trần 20 |
| Màu 16 bit đúng, chế độ được nhớ, đổi giữa hai chế độ 32 bit không nối lại, server giả nhận định dạng pixel đúng thứ tự | `QualityUITests` + `verify_quality.py`: chuỗi `[32, 16, 16, 32, 32, 16]`; màu bốn góc đọc từ ảnh chụp simulator, lệch ≤ 12 so với khung 32 bit |
| Logic | `QualityModeTests` (6), `AdaptiveGovernorTests` (9: hạ, nâng, không dao động, CPU nặng, màn hình đứng yên), `RGB565ConversionTests`/`RGB565DecodingTests` (Raw và cả năm loại tile ZRLE ở 16 bit), `SessionPacingTests` (3) |

Cách đo lại: `rfbprobe --login 30 --probe-encodings`, `--compare-depth 15`, `--check-depth-image`, và `--depth16` cùng `--watch/--record/--replay`. Trên iPad: `devicectl ... --environment-variables '{"RFB_STATS":"1"}' com.ledinhcuong.remotescreen -- -qualityMode bestPerformance` (giá trị `adaptive`, `bestQuality`, `bestPerformance`).

## Chế độ hiển thị (menu "…" › "Hiển thị", nhớ giữa các lần mở)

| Chế độ | Cách làm | Kiểm chứng |
|---|---|---|
| Vừa màn hình | Client thu nhỏ cả màn hình Mac cho vừa | Unit test `DisplayModeTests`; UI test đọc điểm ảnh thật: viền đen đúng chỗ |
| Lấp đầy màn hình | Phủ kín, cắt hai mép, kéo để xem | Như trên: không còn viền đen |
| Điểm ảnh gốc (1:1) | 1 pixel Mac = 1 pixel thiết bị | Như trên: hình 800x600 nhỏ ở giữa trên iPhone 3x |
| **Theo độ phân giải thiết bị** | Nhờ **server Apple thu nhỏ** hình đúng bằng cỡ pixel của khung nhìn (message loại 8, xem `protocol-notes.md` 4g), rồi hiện 1:1. Không đổi màn hình Mac. Tự gửi lại khi xoay máy (chờ 0,3 s cho bố cục yên). Server không phải Apple: như vừa màn hình | `DeviceDisplayModeTests` (5), `AuditFixTests` (định dạng 10 byte, kẹp tỉ lệ, xin lại toàn bộ sau đổi cỡ); Mac thật: 0,5 → 1280x720, 0,75 → 1920x1080 |

Mọi chế độ tự thích ứng khi xoay máy, Split View, Stage Manager: UI test xoay ngang, đọc cỡ đang hiển thị qua giá trị trợ năng của view ("Màn hình Mac 800×600, hiển thị W×H điểm").

**Chưa kiểm chứng ở chế độ "Theo độ phân giải thiết bị"**: toạ độ chuột. App gửi toạ độ trong không gian đã thu nhỏ, và giả định server tự đổi về toạ độ thật như nó làm với vùng xin cập nhật. Kiểm cần một cú chạm thật trên Mac (xem 4g).

## Rà soát (audit) 2026-10-14: hai người rà độc lập, rồi kiểm lại từng phát hiện

Đã sửa, mỗi mục có test (`AuditFixTests`, `CommandHeldTests`, `SensitiveClipboardTests`, `ConnectionDraftAuditTests`, các test cập nhật):

| Phát hiện | Mức | Sửa |
|---|---|---|
| Con trỏ ở 16 bit luôn đọc 4 byte mỗi pixel → lệch luồng, rớt phiên khi con trỏ đổi hình (lỗi do tính năng 16 bit mới đưa vào) | Cao | Đọc theo định dạng client và đổi RGB565 → BGRA. App không xin con trỏ riêng ở 16 bit (chưa đo được server Apple gửi định dạng nào) |
| Thiếu `PrivacyInfo.xcprivacy` (UserDefaults là API phải khai lý do) và biểu tượng app → App Store từ chối | Cao | Thêm tệp khai báo (CA92.1, không theo dõi, không thu thập) và biểu tượng 1024 px tự vẽ (gốc, không dùng hình của Apple) |
| Số phiên bản viết cứng 1.0 (1) trong Info.plist | Thấp | Lấy từ `MARKETING_VERSION`, `CURRENT_PROJECT_VERSION` |
| Hủy bộ đếm giờ chờ mạng vẫn kết thúc luồng trạng thái → **kết nối thất bại đúng lúc người dùng vừa bấm Cho phép Mạng cục bộ** | Trung bình | Bị hủy thì không kết thúc luồng |
| Server độc hại ép cấp phát 1 GB (16384x16384) lặp lại | Trung bình | Trần tổng 64 triệu pixel (đủ 8K) |
| Clipboard Mac quá lớn (ví dụ ⌘C một ảnh) làm rớt cả phiên | Trung bình | Đọc bỏ dữ liệu, báo "Clipboard của Mac quá lớn (x MB) nên đã bỏ qua" |
| Vùng chặn chạm "ma" dưới thanh công cụ sau mỗi lần nối lại (khung của banner không được xóa) | Trung bình | Xóa khung khi banner biến mất |
| ⌘F (lệnh phím ưu tiên) tự nhả ⌘ người dùng đang giữ → ⌘G/⌘V sau đó thành chữ thường | Trung bình | Không gửi lại ⌘ khi ⌘ đang giữ hoặc đang dính |
| Đổi chế độ chất lượng lúc đang nối lại → phiên ở 16 bit trong khi menu ghi "Hiển thị tốt nhất" | Trung bình | Sau khi nối, so độ sâu màu với chế độ và nối lại nếu lệch |
| Nối lại để đổi chất lượng không nhả phím trước → ⌘ có thể kẹt trên Mac | Trung bình | `forceReconnect` nhả phím, nút, phím dính trước khi đóng |
| Nhiều cửa sổ: mỗi cửa sổ một danh sách máy, cửa sổ lưu sau xóa máy của cửa sổ kia | Trung bình | Một `ConnectionsModel` cho cả app; cửa sổ mất tiêu điểm thì nhả phím |
| Lặp phím không có điểm dừng an toàn nếu lần nhả tới view khác | Trung bình | Mất tiêu điểm thì nhả hết; lặp tối đa 30 giây |
| Hủy giữa lúc bắt tay không đóng socket | Thấp-trung bình | `withTaskCancellationHandler` đóng luồng (test: hủy thoát trong < 2 s) |
| CopyRect chép cả vùng qua mảng tạm (chậm, gấp đôi bộ nhớ) | Thấp | `memmove` từng hàng, đúng chiều khi chồng lấn (đối chiếu 7 kiểu chồng lấn) |
| RFB 3.3 gửi thừa byte chọn security type | Thấp | Không gửi ở 3.3 |
| Phiên bị bỏ mà không `close()` giữ kết nối TCP | Thấp (tiềm ẩn) | `NWByteStream.deinit` hủy kết nối |
| Bỏ giới hạn khung hình không giải phóng yêu cầu đang bị hoãn | Thấp | Lên lịch lại theo nhịp mới |
| Thống kê và bộ điều khiển tự động đứng hình khi màn hình tĩnh | Thấp | Chạy theo đồng hồ riêng mỗi giây |
| Chế độ chỉ xem vẫn làm con trỏ vẽ chạy theo ngón tay | Thấp | View bỏ qua cử chỉ điều khiển (kéo và chụm vẫn dịch, phóng khung nhìn) |
| Phím dính bấm lúc đang nối lại bị bỏ mà vẫn hiện "dính" | Thấp | Khóa thanh phím phụ và nút bàn phím khi chưa nối |
| Mật khẩu chép từ trình quản lý mật khẩu trên Mac thành clipboard thường (đồng bộ Universal Clipboard, không hết hạn) | Thấp | Có dấu Concealed/Transient thì ghi chỉ trên máy này, tự xóa sau 90 giây |
| `vnc://tên:mật-khẩu@máy` hiện mật khẩu trong ô tên; `[fe80::1]:5900` không nhận | Thấp | Bỏ phần mật khẩu; hỗ trợ IPv6 trong ngoặc vuông |
| Bonjour hỏng một lần thì không tự tìm lại | Thấp | Tự khởi động lại sau 3 giây |
| Mật khẩu còn trong bộ nhớ sau khi kết nối thất bại | Thấp | Xóa yêu cầu khi thất bại |
| VoiceOver không biết nút bàn phím/phím phụ đang bật | Thấp | Thêm trạng thái "đã chọn"; viên thuốc thu gọn đọc cả trạng thái |

Chưa sửa (có lý do): có thể xé hình khi `replace(region:)` ghi texture lúc GPU đang đọc (cần bộ đệm đôi, chưa thấy trên thực tế); `unsafeFlags(["-O"])` làm gói không dùng được như phụ thuộc theo phiên bản (app dùng gói cục bộ nên không ảnh hưởng); `ITSAppUsesNonExemptEncryption` là khai báo pháp lý về mã hóa (DH, AES, DES chỉ để xác thực), người phát hành phải tự quyết.

Kiểm log: log `screensharingd`/`ScreensharingAgent` 3 giờ qua (67 239 dòng) không có lỗi giao thức nào do app gây ra; "Connection reset by peer" và "No such process" là server ghi nhận khi các phiên test ngắt. Crash log: iPad không có báo cáo nào của app; iPhone có một JetsamEvent liệt kê app (đang tạm dừng, 29 MB, **không** bị giết; tiến trình lớn nhất là Facebook).

## Độ mượt: thăm dò (Pha 0) và thay đổi (Pha 1), 2026-10-14

Vì sao "Hiệu năng tốt nhất" cũ kém mượt: trần 20 khung/s (chủ ý, để tiết kiệm băng thông), 16 bit nên server tự vẽ con trỏ vào khung hình (con trỏ nhích theo nhịp khung), cuộn là nấc bánh xe rời rạc, vẽ ngay khi khung tới thay vì theo nhịp màn hình.

| Thăm dò trên Mac thật (chỉ đọc) | Kết quả |
|---|---|
| Server chụp màn hình nhanh cỡ nào (log `ScreensharingAgent` "screen capture frame count") | ≈ 55 khung/s: server không phải cổ chai |
| ContinuousUpdates (-313) | **Không hỗ trợ** (`rfbprobe --probe-continuous`: không có message 150) |
| Hai yêu cầu cập nhật đang chờ thay vì một | **Không tăng gì**: 36,4 so với 36,5 cập nhật/s, hai kết nối song song (`--compare-outstanding`) |
| Thu nhỏ phía server (loại 8): 1 / 0,92 / 0,46, ba kết nối song song | Số cập nhật/s gần như nhau (~25, theo nhịp nội dung đổi); băng thông 0,46 còn khoảng 1/3. Trên iPad ngang (0,92) gần như không lợi (`--compare-scale`) |
| Thứ tự lệnh thu nhỏ so với yêu cầu đầu tiên | Trước hay sau đều được. **Bắt buộc client khai báo DesktopSize**: không có thì server thu nhỏ xong là ngừng gửi (`--probe-scale-order`) |

Thay đổi:
- **Vẽ theo nhịp màn hình** (`CADisplayLink` của view, dừng khi đứng yên), nhiều cập nhật trong một nhịp gộp thành một lần vẽ. **Hai texture luân phiên**: mỗi cập nhật ghi vào texture GPU không đang đọc (hết nguy cơ xé hình mà audit nêu), mỗi texture nhớ vùng nó còn thiếu nên chỉ tải phần cần, không giữ khung hình (không quay lại lỗi sao chép 14,7 MB). Test GPU thật: `alternatingTexturesStillShowEveryChange`, `anUploadNeverWritesTheTextureTheGPUIsReading`, `resizingWhileTheGPUIsBusyKeepsTheCountsSane`.
- **Quán tính cuộn** (`InputKit/MomentumScroller`): nhấc hai ngón khi đang vuốt thì cuộn tiếp, chậm dần như trackpad (hệ số 0,998/ms như `UIScrollView`), dừng khi chạm lại; đang phóng thì thành kéo khung nhìn có quán tính. Tích phân đúng nên 60 Hz hay 120 Hz cuộn xa như nhau (test).
- **Gộp sự kiện chuột khi mạng nghẽn** (`RFBKit/Session/OutboundQueue.swift`): task ghi lấy hết những gì đang chờ và bỏ những lần di chuột thuần đã bị lần sau thay thế; giữ nguyên vị trí nhấn, mọi lần nhấn/nhả nút (kể cả nấc cuộn), phím, yêu cầu, clipboard.
- **"Hiệu năng tốt nhất"** (giữ tên): không trần khung hình, 32 bit (con trỏ luôn tại chỗ), nhờ server Apple thu nhỏ về độ phân giải khung nhìn. 16 bit chỉ quay lại khi đo được định dạng con trỏ 16 bit của server Apple.
- **Sửa nhỏ**: hết hai con trỏ ở 16 bit (server vẽ một, app vẽ thêm một); phím dính tự nhả sau một cú nhấp (trước chỉ nhả sau một phím); tắt cử chỉ sửa văn bản ba ngón của iPadOS trên màn hình Mac.
- **Số liệu độ mượt** (`SessionKit/FramePacing`): bảng thống kê có thêm "nhịp trung vị/p95 ms" (khoảng cách giữa hai khung có nội dung mới).

Đo sau Pha 1 trên **iPad Air 4 thật → Mac thật** (2026-10-15, bản Debug, `RFB_DROP_INPUT=1`, `RFB_STATS=1`, `RFB_QUALITY=…`, mỗi chế độ ~30 giây, cùng nội dung là cửa sổ terminal đang chạy; trung vị các giây):

| Chế độ | Khung/s | Mbit/s | Giải mã | Vẽ | Nhịp trung vị / p95 |
|---|---|---|---|---|---|
| Tự động | 25 | 16,3 | 1,9 ms | 1,3 ms | 33 / 100 ms |
| Hiển thị tốt nhất | 27 | 16,9 | 1,9 ms | 1,2 ms | 33 / 100 ms |
| Hiệu năng tốt nhất | 25 | 17,8 | 1,9 ms | 1,0 ms | 33 / 100 ms |

"Hiệu năng tốt nhất" từ **17 lên 25 khung/s** (trước Pha 1, do trần 20 và 16 bit) và giờ ngang hai chế độ kia. Giải mã + vẽ chưa tới 3,5 ms mỗi khung, nên iPad không phải cổ chai: trần ~25-30 khung/s là của vòng hỏi-đáp RFB và bộ nén ZRLE phía server (server chụp ~55 khung/s, ContinuousUpdates không có, hai yêu cầu chờ không giúp). Muốn hơn nữa phải là luồng video phần cứng như Sidecar, ngoài phạm vi RFB.

## Sidebar phím bổ trợ kiểu Sidecar (Pha 2), 2026-10-14

Thanh dọc cạnh màn hình Mac (iPad: bên trái, bật sẵn; iPhone: ẩn sẵn vì màn hình hẹp). Menu "…" › Sidebar: trái / phải / ẩn, nhớ giữa các lần mở (`sidebarPosition`). Màn hình Mac nằm **cạnh** sidebar nên co lại, không bị che; "Theo độ phân giải thiết bị" tự tính lại theo phần còn lại. Khi sidebar hiện, thanh công cụ nổi bỏ các nút trùng (ngắt kết nối, bàn phím, phím phụ) và thanh phím phụ bỏ ⌃ ⌥ ⌘ ⇧, che ít thanh menu của Mac hơn.

- Nút: ⌘ ⌥ ⌃ ⇧, Hoàn tác (⌘Z; ⇧ đang dính thì thành ⌘⇧Z), esc, bàn phím, thanh phím phụ, ngắt kết nối.
- Phím bổ trợ (`InputKit/ModifierKeys.swift`, thay `StickyModifiers` cũ, dùng chung cho thanh phím phụ):
  - **Giữ**: đặt ngón là nhấn trên Mac ngay, nhấc là nhả (⌘-click, ⇧-click bằng tay kia).
  - **Dính một lần**: chạm ngắn (≤ 0,4 s, không làm gì trong lúc giữ). Nhả sau phím **hoặc cú nhấp** kế tiếp.
  - **Khóa**: chạm lần hai trong 0,3 s. Giữ qua mọi thao tác, chạm lại để mở. Có biểu tượng ổ khóa.
  - Chạm lại phím đang dính (muộn hơn 0,3 s): bỏ. Mất tiêu điểm, vào nền, chỉ xem, ngắt kết nối, ẩn sidebar (khi thanh phím phụ cũng ẩn): nhả hết, ngược thứ tự nhấn.
- Phím của sidebar là `UIControl` (theo dõi chạm, không phải bộ nhận diện cử chỉ) nên ngón đang giữ ⌘ không chặn cử chỉ của tay kia trên màn hình Mac.
- Test: `ModifierKeysTests` (8, gồm "mỗi lần nhấn có đúng một lần nhả"), `KeyBarModifierTests` (4); UI test `SidebarUITests` + `verify_sidebar.py` (lượt 3 của `run_ui_test.sh`): server giả thấy ⌘↓, đúng một cú nhấp, ⌘↑ (dính); ⌘↓, hai cú nhấp, ⌘↑ (khóa); ⌘↓ z↓ z↑ ⌘↑ (hoàn tác); Escape; không kẹt phím; ẩn sidebar thì màn hình Mac rộng ra.
- **Chưa kiểm**: giữ ⌘ bằng một tay và chạm bằng tay kia (XCUITest không tạo được hai cú chạm độc lập cùng lúc): cần thử tay trên iPad, ví dụ chọn nhiều file trong Finder.

## Apple Pencil, chuột và trackpad của iPad (Pha 3), 2026-10-14

- **Apple Pencil** (`InputKit/PencilGesture.swift`, bộ nhận diện riêng chỉ nhận bút): bút luôn là con trỏ **tuyệt đối** kể cả ở chế độ bàn di chuột. Chạm = nhấp trái tại điểm đặt bút; đi quá 4 point = kéo-thả ngay (không cần giữ trước như ngón tay, tiện bôi chọn văn bản); giữ yên ≥ 0,6 s rồi nhấc = nhấp phải. Chạm vào viền đen ngoài màn hình Mac: không nhấp.
- **Chạm hai lần lên bút** (Pencil 2, Pro; `UIPencilInteraction`): mặc định nhấp phải tại con trỏ; đổi trong menu "…" › Apple Pencil (nhấp phải / hiện-ẩn bàn phím / không làm gì), nhớ giữa các lần mở.
- **Ngón tay chỉ cuộn khi dùng bút** (như Sidecar): sau nét bút đầu tiên, chạm ngón không nhấp, một ngón kéo là cuộn. Mặc định theo cài đặt hệ thống "Chỉ vẽ bằng Apple Pencil" (`UIPencilInteraction.prefersPencilOnlyDrawing`), đổi trong menu.
- **Chuột/trackpad gắn iPad** (`UIApplicationSupportsIndirectInputEvents`): di chuột = di con trỏ Mac (`UIHoverGestureRecognizer`), nút trái nhấn/kéo/nhả tức thì, nút phải = nhấp phải, bánh xe và hai ngón trên trackpad = cuộn Mac (kể cả khi đang phóng), trackpad có quán tính. Con trỏ tròn của iPad ẩn trên màn hình Mac (đã có con trỏ Mac); hiện lại khi chỉ xem hoặc tắt con trỏ Mac.
- Cử chỉ ngón tay giờ chỉ nhận ngón tay (`allowedTouchTypes = [.direct]`), nên bút và chuột không còn bị hiểu như ngón.
- Áp lực và độ nghiêng của bút **không gửi được** qua RFB (sự kiện chuột chỉ có toạ độ và nút).
- Test: `PencilGestureTests` (5), `PointerDeviceTests` (10). **Chưa kiểm trên thiết bị**: simulator và XCUITest không tạo được chạm bút hay chuột gián tiếp. Cần thử tay trên iPad Air 4 + Pencil 2: chạm, kéo chọn chữ, giữ để nhấp phải, chạm hai lần lên bút; và với chuột/trackpad nếu có. Quãng cuộn của một nấc bánh xe chuột chưa đo (có thể cần chỉnh `scrollTickDistance`).

## Cử chỉ thật trên Mac: message loại 23 (Pha 4), 2026-10-14

- Dịch ngược xong phần cần dùng (`docs/protocol-notes.md` mục 4h): loại 11 = `kCGEventScrollWheel` đầy đủ (quãng theo point, pha cuộn, pha quán tính, cờ liên tục), loại 3 = chụm, loại 5 = xoay, loại 4 = phóng thông minh; payload big-endian, server đóng kết nối nếu thiếu byte.
- App (`RFBKit/Protocol/AppleInputEvent.swift`, `ClientMessage.appleEvent`): cuộn mượt kiểu trackpad (began/changed/ended rồi quán tính begin/continue/end, giữ phần lẻ để cuộn chậm không mất) và chụm/xoay (**bản 2 có pha**: began giá trị 0, changed…, ended giá trị 0; con trỏ đưa tới giữa hai ngón trước). Chỉ bật với server Apple.
- Menu "…" › Cử chỉ trên Mac: "Cuộn mượt kiểu trackpad" (**mặc định bật** từ khi thử thật) và "Chụm/xoay hai ngón: Phóng khung nhìn iPad (mặc định, theo lựa chọn của bạn) / Gửi lên Mac". Khi gửi lên Mac, cuộn hai ngón tạm dừng trong lúc chụm/xoay (như trackpad thật).
- Test: `AppleInputEventTests` (5, đối chiếu từng offset với bảng giải mã; chụm/xoay 32 byte bản 2), `AppleGestureMappingTests` (5); đầu-cuối `run_gesture_test.sh` (server giả `--apple` tự xưng `RFB 003.889`, giải payload và log): chụm và xoay tới server đúng cỡ 16 byte, toạ độ trong màn hình, kết nối vẫn sống. XCUITest không tạo được kéo hai ngón nên cuộn mượt chỉ có unit test.
- **Đã thử trên Mac thật (2026-10-15, bạn cho phép)**: `rfbprobe --apple-gesture-test X,Y` gửi vào một cửa sổ AppKit thử (tạo riêng, không đụng cửa sổ nào của bạn) ghi lại `NSEvent` nhận được:
  - Cuộn loại 11: đủ 18 sự kiện, `hasPreciseScrollingDeltas`, `scrollingDeltaY` **đúng bằng** số point gửi (+12 → +12, cùng dấu), pha began/changed/ended → `NSEvent.phase` 1/4/8, quán tính begin/continue/end → `momentumPhase` 1/4/8.
  - Chụm/xoay **bản 1 (không pha): Mac bỏ qua hết**, không có sự kiện nào tới cửa sổ (server vẫn giữ kết nối). **Bản 2 với pha 1/2/4**: tới đủ, `magnification` và `rotation` đúng giá trị và dấu (+3 → +3, ngược chiều kim đồng hồ). Mask (trường 133) thử 0, 2, 4, 8 đều như nhau; app gửi 0.
  - Màn hình Mac này 2560x1440 ở 1x: framebuffer pixel = point, nên `remotePixelsPerMacPoint` đổi mặc định từ 2 sang **1** (giả định Retina cũ làm nội dung chỉ cuộn nửa quãng ngón tay). Mac Retina chưa đo.
  - `rfbprobe --apple-raw FILE --apple-gesture-test X,Y` gửi payload hex tuỳ ý (mỗi dòng `độ_trễ_ms hex`), dùng để thử biến thể.
- Còn chưa biết: toạ độ x, y khi đang thu nhỏ phía server (cùng câu hỏi với `PointerEvent`); loại 4 (phóng thông minh), 6 (vuốt) chưa thử.

## Chưa kiểm chứng, đừng coi là đã xong

- **Chưa gửi chuột/phím thật vào Mac thật từ máy này** (đó là máy làm việc). Mọi kiểm tra nhập liệu trên thiết bị thật dùng server giả. Còn **chưa biết** server Apple có hiểu `Meta_L` (0xFFE7) là phím Command không (xem `KeysymMapper.commandLeft`). App gửi đúng `Meta_L`, đã đo bằng server giả. Cần một lần thử có người ngồi cạnh.
- **Cuộn hai ngón và chụm để phóng** trên thiết bị thật: Device Hub không chuyển cuộn chuột hay chụm thành cử chỉ chạm, nên chỉ có unit test của `TouchMapper`.
- **Gõ tiếng Việt / Unicode** (keysym `0x01000000 + mã`): công cụ gõ của computer use không phát được ký tự này (nó gửi keycode 0 = `a`). Cần người gõ thật trên iPad, và cần biết server Apple có chấp nhận dạng keysym này không.
- **Phím Escape của bàn phím cứng**: không bao giờ tới `pressesBegan`, đo trên iPad thật (qua Device Hub, có console) và trên simulator. Đã thêm `UIKeyCommand` ưu tiên hơn hệ thống nhưng **vẫn chưa thấy Escape tới server** qua Device Hub, nên chưa rõ lỗi nằm ở iPadOS hay ở việc Device Hub không chuyển Escape. Cần thử bằng bàn phím cứng thật. Escape trên thanh phím phụ thì đã đo được.
- **Page Up/Down, Delete xóa tới, F-phím khác F5** trên bàn phím cứng: bảng ánh xạ có (`KeyboardMappingTests`), nhưng chưa tới được server khi gõ qua Device Hub (công cụ không có tên phím đúng) và XCUITest không tạo được chúng. Chưa kiểm trên thiết bị.
- **Lặp phím với Mac thật**: bộ lặp (0,4 s rồi ~15 lần/giây) đã kiểm với server giả. Chưa biết `screensharingd` có tự lặp thêm không (nếu có thì giữ phím sẽ ra gấp đôi). Cần giữ Backspace trên Mac thật để xem.
- **Gõ tiếng Việt từ bàn phím ảo**: dùng keysym Unicode. Binary `ScreensharingAgent` có chuỗi "secure input do not send unicode char" nên server có đường gửi Unicode, và `AppleVNCServer` có `HandleSetKeyboardInputSource` (người xem báo bố cục bàn phím), nhưng chưa thử gõ thật.
- **Đo hiệu năng trên thiết bị thật**: thời gian kết nối, độ mượt, pin chưa đo. Cú chạm đầu tiên ngay sau khi mở app đôi khi không được nhận (chưa rõ do app hay do Device Hub).
- **Khóa con trỏ** (pointer lock, chuột tương đối cho game): chưa làm.
- **Vị trí con trỏ** là vị trí ta gửi lần cuối. RFB không báo khi chuột thật của Mac di chuyển, nên nếu có người dùng chuột thật trên Mac, con trỏ vẽ trên iPad sẽ lệch.
- **Nút Dán của hệ thống (`PasteButton`)**: không phản hồi với cú chạm do Device Hub tạo ra (nó là điều khiển bảo mật của iOS), nên **chưa kiểm được**. Đường ⌘V thì đã kiểm.
- **Hộp thoại "cho phép dán" của iOS**: ⌘V khi clipboard đến từ app khác làm iOS hỏi "RemoteScreen would like to paste from …". Đây là hành vi của iOS, không tránh được nếu app tự đọc clipboard. Người dùng có thể chọn Cho phép trong Cài đặt › RemoteScreen › Dán từ ứng dụng khác, hoặc dùng nút Dán. Bị từ chối thì app báo rõ.
- **Clipboard chỉ văn bản** (UTF-8, tiếng Việt và emoji qua được). Ảnh, tệp, RTF chưa làm. Giao thức riêng của Apple chưa hiểu hết (xem `protocol-notes.md` mục 4e): server có tự đẩy clipboard khi Mac đổi hay không vẫn chưa biết, nên chiều Mac → iPad luôn là hỏi-đáp (sau ⌘C hoặc nút Lấy).
- **Tự kết nối lại**: chưa kiểm trên thiết bị thật các đường sau: quay lại từ nền sau hơn 10 s thì nối lại ngay, `NWPathMonitor` đánh thức khi mạng có lại, keepalive TCP phát hiện kết nối chết (~35 s), hết 6 lần thì bỏ cuộc và hiện lỗi. Có test cho chính sách, không có test đầu-cuối cho các đường này.
- **Lag do băng thông Wi-Fi khi màn hình thay đổi lớn** (hình nền video, phát video, cuộn): luồng có thể lên tới ~77 Mbit/s. Giải mã đã không còn là cổ chai, nhưng chưa đo trên iPad với tải nặng đó (không tạo được tải mà không điều khiển Mac của bạn). Nếu vẫn lag, bước kế là giới hạn tốc độ khung hoặc giảm độ sâu màu (chưa làm).
- **Chế độ Tự động hạ bậc trên thiết bị thật**: logic có test và chạy được, nhưng luồng đo trên iPad (22 Mbit/s) chưa vượt ngưỡng 30 Mbit/s để thấy nó tự hạ. Ngưỡng 30 Mbit/s, 45% CPU và 15 giây là suy luận, chưa chỉnh theo trải nghiệm thật: nếu thấy hạ quá sớm hay quá muộn, chỉnh ở `AdaptiveGovernor`.
- **Chưa có đường nén có tổn hao** (JPEG, HEVC) như Screen Sharing "High Performance": server Apple không nhận Tight, và định dạng riêng của Apple chưa được giải mã.
- **Nhiều màn hình**: chưa làm.
- **Kết nối Bonjour thật tới Mac thật** (chọn "Mac mini" rồi đăng nhập): chưa thử, vì đó là máy làm việc. Đường nối qua `.service` đã được kiểm với dịch vụ giả trong test.
- **Type 31, 32, 33, 35, 36** (SRP và biến thể của Apple): chưa hỗ trợ, xem `protocol-notes.md`.

## Thao tác iPad thật từ Mac bằng computer use (Device Hub)

Xcode 27 không còn `Simulator.app`. `Xcode.app/Contents/Applications/DeviceHub.app` phản chiếu cả simulator lẫn thiết bị thật và nhận chuột/phím. Để thử cử chỉ mà **không** điều khiển Mac thật: chạy `Tools/mock-rfb-server/server.py --host <IP LAN của Mac>` (không có xác thực, chỉ mở lúc thử rồi tắt), mở app bằng `devicectl device process launch --environment-variables '{"RFB_HOST":"<IP>","RFB_PORT":"5959"}'` (chỉ bản DEBUG), rồi đối chiếu `events.jsonl`.

Những điều đã gặp trong môi trường này (có thể khác ở máy khác):

- **Độ lệch toạ độ**: con trỏ thật lệch `+164` pixel ảnh theo trục y so với toạ độ ra lệnh (x đúng). Phải ra lệnh `y - 164`. Công cụ lại chỉ cho nhấp trong cửa sổ đang chạy hoặc thanh menu, nên điểm có y thật nhỏ hơn khoảng 254 khó với tới (thanh công cụ của app với tới được nhờ ra lệnh y=8 trên thanh menu). Kiểm bằng `cursor_position` trước khi tin.
- **Hình phản chiếu trễ khoảng một thao tác**: chờ vài giây rồi hãy chụp, nếu không thấy trạng thái của cú bấm *trước*.
- Nhấp đúp của công cụ đặt cú nhấp thứ hai sai chỗ; hai cú nhấp riêng sát nhau thì đúng.
- Công cụ `type` phát keycode 0 (`a`), có thể để lại phím kẹt trên app: dùng `key` cho từng phím.
- Cuộn chuột không thành sự kiện nào.

## Cờ DEBUG để thử trên thiết bị (chỉ bản Debug, truyền qua `devicectl ... --environment-variables`)

| Biến | Tác dụng |
|---|---|
| `RFB_HOST`, `RFB_PORT`, `RFB_USER`, `RFB_PASSWORD` | Tự nối khi mở app |
| `RFB_SAVE=1` | Lưu máy vào danh sách sau khi nối được (thử luồng lưu mà không gõ form) |
| `RFB_KEYBAR=1` | Mở sẵn thanh phím phụ |
| `RFB_STATS=1` | Mở sẵn bảng thống kê luồng hình, và in `RS_STATS ...` ra console mỗi giây |
| `RFB_DROP_INPUT=1` | **Bỏ mọi sự kiện chuột và phím** trước khi gửi, chỉ cho clipboard đi qua. Dùng khi nối Mac thật để cú bấm trượt không thành chuột thật (đã kiểm: 0 sự kiện chuột/phím tới server giả) |
| `RFB_DEFAULTS_SUITE=<tên>` | Dùng một bộ `UserDefaults` riêng (UI test cô lập cài đặt) |
| `RFB_SIDEBAR=leading\|trailing\|hidden` | Đặt sidebar cho lần chạy này (không lưu) |
| `RFB_SMOOTH_SCROLL=1\|0`, `RFB_PINCH_TO_MAC=1` | Bật/tắt cuộn mượt, bật chụm-xoay lên Mac (message 23) cho lần chạy này |
| `RFB_QUALITY=adaptive\|bestQuality\|bestPerformance` | Chế độ chất lượng cho lần chạy này (không lưu), để đo từng chế độ trên iPad bằng `devicectl` |

## Hai lỗi chỉ lộ ra trên thiết bị thật

- Chạm thanh công cụ vừa không kích hoạt nút vừa **nhấp xuống Mac ngay dưới nó**. Nút SwiftUI nằm đè lên `UIViewRepresentable` không nhận cú chạm nếu vùng đó không có cử chỉ SwiftUI (`claimingTouches` trong `Views.swift`), và `RemoteScreenView.excludedRegions` chặn cử chỉ một ngón trong vùng đó. Cử chỉ nhiều ngón không bị chặn.
- Option+chữ gửi ký tự đã soạn (`≈`) thay vì phím gốc (`x`). Đã sửa: Option cũng dùng `charactersIgnoringModifiers`.

## Điểm có thể chỉnh theo thói quen: `TouchPolicy` (Sources/InputKit/TouchMapping.swift)

Hai hàm quyết định cử chỉ nào làm gì, đã có giá trị mặc định:

- `oneFingerDrag(isZoomed:)`: một ngón kéo thì **di chuyển con trỏ**, **kéo-thả**, hay **kéo khung nhìn**. Mặc định: chế độ trackpad luôn di chuyển con trỏ; chạm trực tiếp thì kéo khung nhìn khi đang phóng, ngược lại di chuyển con trỏ. Kéo-thả thật dùng nhấn giữ rồi kéo.
- `twoFingerPan(isZoomed:)`: hai ngón kéo thì **cuộn** hay **kéo khung nhìn**. Mặc định cuộn, trừ khi đang phóng.

Đây là quyết định UX cốt lõi và chỉ người dùng thật mới đánh giá được cảm giác đúng. Đổi giá trị trả về là đủ, các test sẽ cho biết chỗ nào phụ thuộc vào lựa chọn cũ.
