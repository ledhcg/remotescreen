import Foundation

/// Số liệu độ mượt: khoảng cách giữa các lần hiện một khung có nội dung mới, và số cập nhật đã gộp vào mỗi lần hiện.
///
/// Khung/giây không nói lên độ mượt: 25 khung/s đều đặn (40 ms một khung) mượt hơn 25 khung/s mà có lúc 16 ms, có lúc 120 ms.
/// p95 của khoảng cách là thứ mắt cảm nhận là "giật".
public struct FramePacing: Sendable, Equatable {
    private var lastPresent: Double?
    private var intervals: [Double] = []
    private var merged = 0
    private var presents = 0

    public init() {}

    /// - Parameters:
    ///   - time: thời điểm hiện (giây).
    ///   - mergedUpdates: số cập nhật của server được gộp vào lần hiện này (lớn hơn 1 là đã đỡ được việc thừa).
    public mutating func recordPresent(at time: Double, mergedUpdates: Int) {
        if let lastPresent, time > lastPresent { intervals.append((time - lastPresent) * 1000) }
        lastPresent = time
        merged += mergedUpdates
        presents += 1
    }

    public struct Summary: Equatable, Sendable {
        /// Khoảng cách giữa hai lần hiện, mili giây.
        public var medianInterval: Double
        public var p95Interval: Double
        /// Trung bình số cập nhật gộp vào mỗi lần hiện.
        public var updatesPerPresent: Double
    }

    /// Trả số liệu từ lần gọi trước tới giờ rồi bắt đầu cửa sổ mới (giữ mốc thời gian để khoảng cách đầu cửa sổ sau vẫn đúng).
    public mutating func drain() -> Summary? {
        defer {
            intervals.removeAll(keepingCapacity: true)
            merged = 0
            presents = 0
        }
        guard !intervals.isEmpty, presents > 0 else { return nil }
        let sorted = intervals.sorted()
        func percentile(_ p: Double) -> Double { sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * p).rounded()))] }
        return Summary(medianInterval: percentile(0.5), p95Interval: percentile(0.95), updatesPerPresent: Double(merged) / Double(presents))
    }

    /// Quên mốc thời gian (ví dụ màn hình đứng yên lâu): khoảng nghỉ đó không phải là "giật".
    public mutating func resetBaseline() {
        lastPresent = nil
    }
}
