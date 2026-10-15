import CoreGraphics
import Foundation

/// Quán tính sau khi nhấc hai ngón cuộn, như trackpad của Mac và `UIScrollView`: tiếp tục cuộn theo vận tốc lúc nhả, chậm dần
/// theo cấp số nhân, dừng khi đủ chậm hoặc khi người dùng chạm lại. Thuần toán học: view gọi `advance` mỗi nhịp màn hình và đưa
/// quãng trả về vào đúng đường cuộn hiện có (nấc bánh xe, hoặc dịch khung nhìn khi đang phóng).
public struct MomentumScroller: Sendable, Equatable {
    /// Hệ số giảm mỗi mili giây, bằng `UIScrollView.DecelerationRate.normal` (0,998): sau 1 giây còn khoảng 13% vận tốc.
    public static let decayPerMillisecond = 0.998
    /// Nhả tay chậm hơn mức này (point/giây) thì không có quán tính: đó là dừng lại, không phải vuốt.
    public static let startSpeed = 200.0
    /// Chậm hơn mức này thì dừng.
    public static let stopSpeed = 20.0

    public private(set) var velocity = CGPoint.zero
    /// Vị trí hai ngón lúc nhả (để cuộn tại đúng chỗ đó ở chế độ chạm trực tiếp).
    public private(set) var location = CGPoint.zero
    public private(set) var isActive = false

    public init() {}

    /// Bắt đầu quán tính nếu vuốt đủ nhanh. Trả về `true` nếu đã bắt đầu.
    @discardableResult
    public mutating func start(velocity: CGPoint, at location: CGPoint) -> Bool {
        guard hypot(velocity.x, velocity.y) >= Self.startSpeed else {
            stop()
            return false
        }
        self.velocity = velocity
        self.location = location
        isActive = true
        return true
    }

    public mutating func stop() {
        isActive = false
        velocity = .zero
    }

    /// Quãng đi được trong `seconds` giây kể từ lần trước (tích phân đúng của vận tốc giảm theo cấp số nhân, nên kết quả không
    /// phụ thuộc nhịp màn hình 60 hay 120 Hz). Trả `.zero` và tự dừng khi đủ chậm.
    public mutating func advance(by seconds: Double) -> CGPoint {
        guard isActive, seconds > 0 else { return .zero }
        let milliseconds = seconds * 1000
        let factor = pow(Self.decayPerMillisecond, milliseconds)
        // ∫ v·d^t dt từ 0 tới T (t tính bằng ms) = v·(d^T − 1)/ln(d), đổi đơn vị ms → s.
        let distanceFactor = (factor - 1) / log(Self.decayPerMillisecond) / 1000
        let travelled = CGPoint(x: velocity.x * distanceFactor, y: velocity.y * distanceFactor)
        velocity = CGPoint(x: velocity.x * factor, y: velocity.y * factor)
        if hypot(velocity.x, velocity.y) < Self.stopSpeed { isActive = false }
        return travelled
    }
}
