import CoreGraphics
import Foundation

/// Việc một nét bút Apple Pencil làm trên Mac. Toạ độ là toạ độ view (point); `TouchMapper` đổi sang pixel Mac.
public enum PencilAction: Sendable, Equatable {
    /// Nhấn nút trái tại điểm bắt đầu nét (bắt đầu kéo-thả, bôi chọn văn bản).
    case press(CGPoint)
    /// Kéo tiếp, nút trái vẫn nhấn.
    case move(CGPoint)
    /// Nhả nút trái (hết kéo).
    case release(CGPoint)
    /// Nhấp trái (chạm bút).
    case click(CGPoint)
    /// Nhấp phải (giữ bút yên lâu).
    case rightClick(CGPoint)
}

/// Phân loại một nét bút: chạm, kéo hay giữ yên. Thuần (thời gian truyền vào) nên test được không cần UI.
///
/// Bút là con trỏ **tuyệt đối, chính xác** bất kể chế độ chạm trực tiếp hay bàn di chuột: đầu bút ở đâu thì con trỏ Mac ở đó.
/// - Chạm rồi nhấc (ngắn hơn `rightClickDuration`, không đi quá `slop`): nhấp trái.
/// - Đi quá `slop`: kéo-thả ngay, không cần giữ trước như ngón tay (bút không cần phân biệt với cuộn).
/// - Giữ yên từ `rightClickDuration` trở lên rồi nhấc: nhấp phải.
public struct PencilGesture: Sendable, Equatable {
    /// Quãng đầu bút được phép xê dịch mà vẫn tính là chạm, point. Nhỏ hơn ngón tay nhiều vì đầu bút chính xác.
    public static let slop: CGFloat = 4
    public static let rightClickDuration = 0.6

    private var start: CGPoint?
    private var startTime = 0.0
    private var last = CGPoint.zero
    private var isDragging = false

    public init() {}

    public mutating func began(at point: CGPoint, time: Double) -> [PencilAction] {
        start = point
        startTime = time
        last = point
        isDragging = false
        return []
    }

    public mutating func moved(to point: CGPoint, time: Double) -> [PencilAction] {
        guard let start else { return [] }
        last = point
        if isDragging { return [.move(point)] }
        guard hypot(point.x - start.x, point.y - start.y) > Self.slop else { return [] }
        isDragging = true
        return [.press(start), .move(point)]
    }

    public mutating func ended(at point: CGPoint, time: Double) -> [PencilAction] {
        guard let start else { return [] }
        defer { reset() }
        if isDragging { return [.move(point), .release(point)] }
        return time - startTime >= Self.rightClickDuration ? [.rightClick(start)] : [.click(start)]
    }

    /// Nét bị hủy (hệ thống lấy cú chạm): đang kéo thì nhả, không thì bỏ qua (không nhấp nhầm).
    public mutating func cancelled() -> [PencilAction] {
        defer { reset() }
        return isDragging ? [.release(last)] : []
    }

    private mutating func reset() {
        start = nil
        isDragging = false
    }
}
