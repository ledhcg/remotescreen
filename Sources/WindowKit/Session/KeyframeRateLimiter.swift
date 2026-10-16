import Foundation
import LinkProtocol

/// Limits `stream.keyframe` requests per window. A broken stream makes the decoder ask for a key frame on every bad access unit, and a
/// key frame is much bigger than a delta frame, so asking more often than the helper can answer only makes things worse.
///
/// At most one request per `minInterval` per window (0.5 s = two per second). A request that arrives too early is **deferred**, not
/// lost: `due(now:)` returns it once the interval has passed, so the last request always gets through.
/// Pure logic; the owner supplies the clock and sleeps until `nextDeadline`.
public struct KeyframeRateLimiter: Sendable, Equatable {
    public enum Decision: Sendable, Equatable {
        case sendNow
        /// Too soon; the request is remembered and `due(now:)` returns it at or after `until`.
        case deferred(until: TimeInterval)
    }

    public var minInterval: TimeInterval
    private var lastSent: [WindowID: TimeInterval] = [:]
    private var pending: [WindowID: TimeInterval] = [:]

    public init(minInterval: TimeInterval = 0.5) { self.minInterval = minInterval }

    public mutating func request(_ window: WindowID, now: TimeInterval) -> Decision {
        if let last = lastSent[window], now - last < minInterval {
            let until = last + minInterval
            pending[window] = until
            return .deferred(until: until)
        }
        lastSent[window] = now
        pending[window] = nil
        return .sendNow
    }

    /// Deferred requests whose time has come. They count as sent.
    public mutating func due(now: TimeInterval) -> [WindowID] {
        let ready = pending.filter { $0.value <= now }.keys.sorted()
        for window in ready {
            pending[window] = nil
            lastSent[window] = now
        }
        return ready
    }

    /// When `due(now:)` will next return something, or `nil` when nothing is deferred.
    public var nextDeadline: TimeInterval? { pending.values.min() }

    /// A window went away (or its stream was restarted): its history and deferred request are void.
    public mutating func forget(_ window: WindowID) {
        lastSent[window] = nil
        pending[window] = nil
    }

    public mutating func reset() {
        lastSent.removeAll()
        pending.removeAll()
    }
}
