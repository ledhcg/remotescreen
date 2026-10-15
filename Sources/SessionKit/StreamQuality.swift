import Foundation
import RFBKit

/// Độ sâu màu yêu cầu server gửi. Chọn khi **kết nối** (đổi giữa phiên là đổi định dạng pixel khi có cập nhật đang bay, mà RFB
/// không có dấu hiệu nào cho biết cập nhật nào dùng định dạng nào, nên app kết nối lại thay vì đoán).
public enum ColorDepth: Sendable, Equatable {
    /// 32 bit, không mất màu.
    case full
    /// 16 bit (5-6-5): trên Mac thật, khung đầy đủ còn khoảng 51% dung lượng và luồng chuyển động còn 65-71%. Server Apple không
    /// nhận 8 bit.
    case reduced

    public var pixelFormat: PixelFormat { self == .full ? .bgra8888 : .rgb565 }
}

/// Chế độ chất lượng người dùng chọn, giống mục Adaptive/Full Quality của Screen Sharing nhưng có thêm "hiệu năng tốt nhất".
public enum QualityMode: String, CaseIterable, Sendable {
    /// Màu đầy đủ; app tự giảm số khung hình mỗi giây khi luồng nặng (mạng hoặc CPU) và tăng lại khi nhẹ.
    case adaptive
    /// Màu đầy đủ, tốc độ khung hình cao nhất có thể.
    case bestQuality
    /// Ưu tiên **độ mượt**: không giới hạn khung hình, con trỏ luôn vẽ tại chỗ, và với Mac thì nhờ server thu nhỏ hình về đúng
    /// độ phân giải khung nhìn (ít pixel phải nén và gửi hơn).
    ///
    /// Trước đây chế độ này là 16 bit + trần 20 khung/s: tiết kiệm băng thông nhưng kém mượt (đo trên iPad: 17 khung/s so với 25),
    /// và ở 16 bit server tự vẽ con trỏ vào khung hình nên con trỏ nhích theo nhịp khung. 16 bit chỉ quay lại khi đo được server
    /// Apple gửi hình con trỏ 16 bit ra sao (để giữ con trỏ tại chỗ); xem `ColorDepth`.
    case bestPerformance

    public static let `default` = QualityMode.adaptive

    /// Độ sâu màu của chế độ. Không đổi trong phiên (xem `ColorDepth`).
    public var colorDepth: ColorDepth { .full }

    /// Nhờ server Apple thu nhỏ hình về độ phân giải khung nhìn (message loại 8), bất kể chế độ hiển thị.
    public var prefersServerScaling: Bool { self == .bestPerformance }

    /// Trần khung hình ban đầu: `nil` là không giới hạn. Với `.adaptive`, `AdaptiveGovernor` đổi giá trị này theo tải.
    public var initialMaxFramesPerSecond: Int? { nil }
}

extension Optional where Wrapped == Int {
    /// Giãn cách tối thiểu giữa hai lần xin cập nhật tương ứng với trần khung hình.
    public var minimumUpdateInterval: Duration? {
        map { .nanoseconds(1_000_000_000 / Swift.max($0, 1)) }
    }
}

/// Bộ điều khiển cho chế độ `.adaptive`: nhìn số liệu từng giây của luồng hình và quyết định có hạ hay nâng trần khung hình.
///
/// Thiết kế để **không dao động**: hạ nhanh (3 giây nặng liên tiếp) nhưng nâng chậm (15 giây nhẹ liên tiếp), mỗi lần một bậc,
/// và một giây "lưng chừng" làm đếm lại từ đầu. Trần khung hình là núm duy nhất nó điều chỉnh, vì độ sâu màu không đổi được
/// giữa phiên (xem `ColorDepth`).
public struct AdaptiveGovernor: Sendable, Equatable {
    /// Các bậc, từ nhanh nhất tới tiết kiệm nhất.
    public static let ladder: [Int?] = [nil, 30, 20, 12]

    /// Nặng: ≥ 30 Mbit/s (Wi-Fi thường chịu không nổi lâu), hoặc CPU dành ≥ 45% thời gian cho giải mã và vẽ.
    public static let heavyMegabits = 30.0
    public static let heavyBusyFraction = 0.45
    /// Nhẹ: ≤ 10 Mbit/s và CPU ≤ 15%. Giữa hai ngưỡng là vùng lưng chừng, không hạ cũng không nâng.
    public static let calmMegabits = 10.0
    public static let calmBusyFraction = 0.15
    public static let windowsToDegrade = 3
    public static let windowsToRestore = 15

    public private(set) var level = 0
    private var heavyStreak = 0
    private var calmStreak = 0

    public init() {}

    public var maxFramesPerSecond: Int? { Self.ladder[level] }

    public struct Change: Equatable, Sendable {
        public var level: Int
        public var maxFramesPerSecond: Int?
    }

    /// Tỷ lệ thời gian CPU dành cho luồng hình trong cửa sổ: (giải mã + vẽ) mỗi cập nhật × số cập nhật mỗi giây.
    static func busyFraction(_ stats: StreamStats) -> Double {
        (stats.decodeMilliseconds + stats.drawMilliseconds) * stats.updatesPerSecond / 1000
    }

    /// Nhận số liệu của một cửa sổ (khoảng một giây). Trả về thay đổi nếu cần đổi trần khung hình.
    public mutating func observe(_ stats: StreamStats) -> Change? {
        let busy = Self.busyFraction(stats)
        if stats.megabitsPerSecond >= Self.heavyMegabits || busy >= Self.heavyBusyFraction {
            heavyStreak += 1
            calmStreak = 0
        } else if stats.megabitsPerSecond <= Self.calmMegabits && busy <= Self.calmBusyFraction {
            calmStreak += 1
            heavyStreak = 0
        } else {
            heavyStreak = 0
            calmStreak = 0
        }

        if heavyStreak >= Self.windowsToDegrade, level < Self.ladder.count - 1 {
            return move(to: level + 1)
        }
        if calmStreak >= Self.windowsToRestore, level > 0 {
            return move(to: level - 1)
        }
        return nil
    }

    private mutating func move(to newLevel: Int) -> Change {
        level = newLevel
        heavyStreak = 0
        calmStreak = 0
        return Change(level: newLevel, maxFramesPerSecond: Self.ladder[newLevel])
    }
}
