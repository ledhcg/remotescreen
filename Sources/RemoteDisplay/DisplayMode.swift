import Foundation

/// Cách đặt màn hình Mac lên màn hình iPad/iPhone, người dùng chọn trong menu và được nhớ giữa các lần mở app.
///
/// Mọi chế độ đều **tự thích ứng** khi khung nhìn đổi cỡ (xoay máy, Split View, Stage Manager): tỉ lệ được tính lại từ cỡ mới
/// mỗi lần bố cục (`ViewportGeometry.updateViewSize`), không cần làm gì thêm.
///
/// Không đổi độ phân giải của chính Mac: server Apple không nhận `SetDesktopSize` của RFB chuẩn, và message riêng loại 29
/// (`SetDisplayConfiguration`) tạo màn hình ảo, có thể làm tối màn hình thật. `.device` dùng message loại 8 (server thu nhỏ hình
/// cho riêng người xem này), xem `protocol-notes.md` 4g.
public enum DisplayMode: String, CaseIterable, Sendable {
    /// Thấy toàn bộ màn hình Mac, thu nhỏ cho vừa, có viền đen nếu khác tỉ lệ.
    case fit
    /// Phủ kín màn hình thiết bị, cắt phần thừa ở hai mép; kéo hai ngón để xem phần bị cắt.
    case fill
    /// Mỗi pixel Mac là đúng một pixel của thiết bị: nét nhất, không co giãn; kéo để xem phần ngoài khung.
    case native
    /// Theo độ phân giải thiết bị: server Apple thu nhỏ màn hình Mac xuống đúng cỡ pixel của khung nhìn trước khi gửi, nên hình
    /// hiện 1:1 (nét như điểm ảnh gốc) mà vẫn thấy toàn màn hình, và ít byte hơn hẳn (iPhone dọc: còn khoảng 1/5). Tự tính lại khi
    /// xoay máy. Với server không phải Apple thì như `.fit`.
    case device

    public static let `default` = DisplayMode.fit

    /// - Parameter screenScale: số pixel thiết bị trên mỗi point (`UIScreen.scale`, 2 trên iPad, 3 trên iPhone Pro).
    public func scaleMode(screenScale: Double) -> ViewportGeometry.ScaleMode {
        switch self {
        case .fit: .fit
        case .fill: .fill
        case .native: .pixelPerfect(screenScale: screenScale)
        case .device: .fit // server đã thu nhỏ đúng cỡ khung nhìn, nên "vừa" chính là 1:1
        }
    }

    /// Tỉ lệ nhờ server thu nhỏ: vừa khung nhìn `viewPixels` (pixel thiết bị), không bao giờ phóng to (tối đa 1).
    /// `nil` nếu chế độ này không dùng thu nhỏ phía server hoặc cỡ không hợp lệ.
    public func serverScale(remote: CGSize, viewPixels: CGSize) -> Double? {
        guard self == .device, remote.width > 0, remote.height > 0, viewPixels.width > 0, viewPixels.height > 0 else { return nil }
        return min(1, viewPixels.width / remote.width, viewPixels.height / remote.height)
    }
}
