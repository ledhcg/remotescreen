import Foundation

/// Số liệu luồng hình trong một khoảng thời gian: dùng để biết lag là do mạng, giải mã hay vẽ.
public struct StreamStats: Equatable, Sendable {
    public var updatesPerSecond: Double
    public var megabitsPerSecond: Double
    /// Thời gian CPU giải mã trung bình mỗi cập nhật.
    public var decodeMilliseconds: Double
    /// Thời gian tải lên GPU trung bình mỗi cập nhật (trên main thread).
    public var drawMilliseconds: Double
    /// Độ đều của khung hình hiện trên màn hình (trung vị và p95 khoảng cách giữa hai khung), nếu đo được trong cửa sổ.
    public var pacing: FramePacing.Summary?

    public init(updatesPerSecond: Double, megabitsPerSecond: Double, decodeMilliseconds: Double, drawMilliseconds: Double) {
        self.updatesPerSecond = updatesPerSecond
        self.megabitsPerSecond = megabitsPerSecond
        self.decodeMilliseconds = decodeMilliseconds
        self.drawMilliseconds = drawMilliseconds
    }

    /// Tính từ số liệu thô của một cửa sổ đo. `nil` nếu cửa sổ không có thời lượng.
    public static func measure(updates: Int, wireBytes: Int, decode: Duration, draw: Duration, over elapsed: Duration) -> StreamStats? {
        let seconds = elapsed.seconds
        guard seconds > 0, updates >= 0 else { return nil }
        let perUpdate = updates > 0 ? Double(updates) : 1
        return StreamStats(
            updatesPerSecond: Double(updates) / seconds,
            megabitsPerSecond: Double(wireBytes) * 8 / 1_000_000 / seconds,
            decodeMilliseconds: decode.seconds * 1000 / perUpdate,
            drawMilliseconds: draw.seconds * 1000 / perUpdate
        )
    }

    /// Một dòng gọn cho bảng thống kê.
    public var summary: String {
        func number(_ value: Double, _ digits: Int) -> String {
            value.formatted(.number.precision(.fractionLength(digits)).locale(Locale(identifier: "vi_VN")))
        }
        var line = "\(number(updatesPerSecond, 0)) khung/s · \(number(megabitsPerSecond, 1)) Mbit/s · "
            + "giải mã \(number(decodeMilliseconds, 1)) ms · vẽ \(number(drawMilliseconds, 1)) ms"
        if let pacing {
            line += " · nhịp \(number(pacing.medianInterval, 0))/\(number(pacing.p95Interval, 0)) ms"
        }
        return line
    }
}

extension Duration {
    var seconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}
