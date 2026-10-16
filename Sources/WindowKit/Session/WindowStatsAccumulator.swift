import Foundation
import LinkProtocol

/// Counters of one window between two `stats` reports. The helper wants **deltas** (what happened in the last 250 ms), while the
/// decoder only keeps running totals, so this remembers the totals of the previous report.
public struct WindowStatsAccumulator: Sendable, Equatable {
    private var receivedBytes: UInt64 = 0
    private var lastDecodedTotal = 0
    private var lastDroppedTotal = 0

    public init() {}

    /// Counts bytes of a received `video.frame` (or any payload of this window's stream).
    public mutating func addReceived(bytes: Int) {
        guard bytes > 0 else { return }
        receivedBytes &+= UInt64(bytes)
    }

    /// Builds the report and starts a new period.
    /// - Parameters:
    ///   - decodedTotal / droppedTotal: running totals of the decoder. A total that went down (new decoder after a reset)
    ///     counts as a fresh start, so the report never shows a negative or wrapped number.
    ///   - decodeP95Micros: decode time p95 over the decoder's recent frames.
    public mutating func report(window: WindowID, decodedTotal: Int, droppedTotal: Int, decodeP95Micros: UInt32) -> LinkWindowStats {
        let decoded = decodedTotal >= lastDecodedTotal ? decodedTotal - lastDecodedTotal : decodedTotal
        let dropped = droppedTotal >= lastDroppedTotal ? droppedTotal - lastDroppedTotal : droppedTotal
        defer {
            receivedBytes = 0
            lastDecodedTotal = decodedTotal
            lastDroppedTotal = droppedTotal
        }
        return LinkWindowStats(
            window: window, receivedBytes: receivedBytes, decodedFrames: UInt32(clamping: decoded),
            droppedFrames: UInt32(clamping: dropped), decodeP95Micros: decodeP95Micros
        )
    }
}

/// What a decoder reports about itself when stats are collected.
public struct DecoderCounters: Sendable, Equatable {
    public var decodedTotal: Int
    public var droppedTotal: Int
    public var decodeP95Millis: Double

    public init(decodedTotal: Int, droppedTotal: Int, decodeP95Millis: Double) {
        self.decodedTotal = decodedTotal
        self.droppedTotal = droppedTotal
        self.decodeP95Millis = decodeP95Millis
    }

    var p95Micros: UInt32 {
        guard decodeP95Millis.isFinite, decodeP95Millis > 0 else { return 0 }
        return UInt32(exactly: min((decodeP95Millis * 1000).rounded(), Double(UInt32.max))) ?? UInt32.max
    }
}

/// The accumulators of all windows of one connection, and the `stats` message built from them every period.
public struct ConnectionStatsBook: Sendable, Equatable {
    private var windows: [WindowID: WindowStatsAccumulator] = [:]

    public init() {}

    public mutating func addReceived(window: WindowID, bytes: Int) {
        windows[window, default: WindowStatsAccumulator()].addReceived(bytes: bytes)
    }

    public mutating func forget(window: WindowID) { windows[window] = nil }

    public mutating func reset() { windows.removeAll() }

    /// One `stats` message for the windows in `counters` (the windows currently decoded). `nil` when there is nothing to say.
    /// Windows are reported in id order and capped at `LinkLimits.maxStatsWindows`.
    public mutating func makeStats(rttMicros: UInt32, counters: [WindowID: DecoderCounters]) -> LinkStats? {
        guard !counters.isEmpty else { return nil }
        var reports: [LinkWindowStats] = []
        for id in counters.keys.sorted().prefix(LinkLimits.maxStatsWindows) {
            guard let counter = counters[id] else { continue }
            reports.append(windows[id, default: WindowStatsAccumulator()].report(
                window: id, decodedTotal: counter.decodedTotal, droppedTotal: counter.droppedTotal, decodeP95Micros: counter.p95Micros
            ))
        }
        // Forget windows that are no longer decoded so their byte counters do not grow forever.
        for id in windows.keys where counters[id] == nil { windows[id] = nil }
        return LinkStats(rttMicros: rttMicros, windows: reports)
    }
}
