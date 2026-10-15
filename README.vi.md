# RemoteScreen

**Điều khiển máy Mac từ iPhone hoặc iPad.** Ứng dụng Swift thuần, không phụ thuộc thư viện ngoài, kết nối tới Apple
Screen Sharing (RFB / VNC, gồm cả đăng nhập type 30 của Apple), thiết kế cho cảm ứng, Apple Pencil, chuột và trackpad.

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

[English](README.md) · [Tiếng Việt](README.vi.md)

> **Trạng thái: giai đoạn đầu (0.1.0).** Chạy được với Mac thật (macOS 27) và iPad thật, nhưng tên app và bundle id
> vẫn là tạm thời, một số tính năng chưa được kiểm chứng. Xem [docs/app-status.md](docs/app-status.md).

## Tính năng

- Client RFB tự viết, không phụ thuộc bên thứ ba: xác thực None / VNC / Apple Remote Desktop (type 30), giải mã
  Raw, CopyRect, ZRLE, con trỏ, clipboard.
- Vẽ bằng Metal, có letterbox, thu phóng, kích thước thật và con trỏ từ xa đúng vị trí.
- Cảm ứng như một con trỏ: chạm, chạm đúp, chạm hai ngón (nhấp phải), nhấn giữ để kéo, cuộn có quán tính, Apple Pencil,
  chuột/trackpad của iPad.
- Bàn phím cứng và bàn phím ảo, phím bổ trợ dính.
- Tìm máy bằng Bonjour, lưu máy; mật khẩu nằm trong Keychain (`WhenUnlockedThisDeviceOnly`), không nằm trong danh sách.
- Chế độ chất lượng hình, tự kết nối lại, đồng bộ clipboard.

## Lưu ý bảo mật

- Chỉ đăng nhập type 30 của Apple bảo vệ thông tin đăng nhập. **Màn hình, phím gõ và clipboard đi không mã hoá qua RFB.**
  Hãy dùng trong mạng tin cậy hoặc đi qua đường hầm (SSH, VPN).
- Xác thực VNC (type 2) dùng DES nên yếu. Nên dùng đăng nhập tài khoản (type 30).
- Nếu đã nhập tên tài khoản mà server chỉ chào xác thực VNC, kết nối bị từ chối thay vì tự hạ cấp. Muốn dùng mật khẩu VNC
  thì để trống tên tài khoản. Đăng nhập yếu sẽ có cảnh báo suốt phiên.
- Trao đổi khoá của Apple (type 30) không xác thực server nên kẻ ở giữa vẫn giả được. Client từ chối nhóm Diffie-Hellman yếu
  (dưới 2048 bit, hợp số, cấu trúc lạ), nhưng việc này không thay thế mạng tin cậy.
- Clipboard: với server VNC chuẩn, văn bản server tự đẩy **không** được ghi vào clipboard iOS; chỉ chép ngay sau khi bạn sao chép
  trên Mac hoặc bấm nút. Đồng bộ với macOS dùng giao thức hỏi-đáp của Apple.
- Số học số lớn không chạy trong thời gian hằng số. Đủ cho khoá tạm thời của mỗi kết nối trong phiên tương tác.

## Build

Cần Xcode 26+ (Swift 6), iOS 18+.

```bash
swift build && swift test            # các gói (macOS), 55 test, không cần thiết bị
cd App && xcodegen generate          # sinh RemoteScreenApp.xcodeproj (không commit)
```

Chạy trên thiết bị thật cần team Apple Developer, đặt trong `App/Signing.local.xcconfig` (đã gitignore):

```
DEVELOPMENT_TEAM = <TEAM_ID_CỦA_BẠN>
CODE_SIGN_STYLE = Automatic
```

Hãy đổi `bundleIdPrefix` / `PRODUCT_BUNDLE_IDENTIFIER` trong `App/project.yml` thành của bạn.

Cấu trúc thư mục và công cụ (`rfbprobe`, `mock-rfb-server`) được mô tả trong [README.md](README.md) và
[docs/app-status.md](docs/app-status.md). `rfbprobe --record` ghi dữ liệu chứa nội dung màn hình: không commit.

## Nhãn hiệu

Apple, Mac, macOS, iPad, iPhone, Screen Sharing, Apple Remote Desktop là nhãn hiệu của Apple Inc. VNC là nhãn hiệu của
RealVNC Ltd. RemoteScreen là dự án độc lập, không liên kết với hay được bảo trợ bởi Apple hoặc RealVNC.

## Giấy phép

[MIT](LICENSE)
