import Foundation

/// Smoothness statistics: the gap between presentations of a frame with new content, and how many updates were merged into each presentation.
///
/// Frames per second says nothing about smoothness: a steady 25 fps (40 ms per frame) is smoother than 25 fps that alternates between 16 ms and 120 ms.
/// The p95 of the gap is what the eye perceives as stutter.
public struct FramePacing: Sendable, Equatable {
    private var lastPresent: Double?
    private var intervals: [Double] = []
    private var merged = 0
    private var presents = 0

    public init() {}

    /// - Parameters:
    ///   - time: time of presentation (seconds).
    ///   - mergedUpdates: number of server updates merged into this presentation (greater than 1 means redundant work was saved).
    public mutating func recordPresent(at time: Double, mergedUpdates: Int) {
        if let lastPresent, time > lastPresent { intervals.append((time - lastPresent) * 1000) }
        lastPresent = time
        merged += mergedUpdates
        presents += 1
    }

    public struct Summary: Equatable, Sendable {
        /// Gap between two presentations, in milliseconds.
        public var medianInterval: Double
        public var p95Interval: Double
        /// Average number of updates merged into each presentation.
        public var updatesPerPresent: Double
    }

    /// Returns the statistics since the previous call and starts a new window (keeping the last timestamp so the first gap of the next window is still correct).
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

    /// Forgets the last timestamp (for example after the screen sat idle for a while): that pause is not stutter.
    public mutating func resetBaseline() {
        lastPresent = nil
    }
}
