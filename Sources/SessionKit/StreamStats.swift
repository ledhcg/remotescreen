import Foundation
import Localization

/// Stream statistics over a time window: used to tell whether lag comes from the network, decoding or drawing.
public struct StreamStats: Equatable, Sendable {
    public var updatesPerSecond: Double
    public var megabitsPerSecond: Double
    /// Average CPU time spent decoding per update.
    public var decodeMilliseconds: Double
    /// Average time spent uploading to the GPU per update (on the main thread).
    public var drawMilliseconds: Double
    /// Smoothness of the frames shown on screen (median and p95 of the gap between two frames), if measured in the window.
    public var pacing: FramePacing.Summary?

    public init(updatesPerSecond: Double, megabitsPerSecond: Double, decodeMilliseconds: Double, drawMilliseconds: Double) {
        self.updatesPerSecond = updatesPerSecond
        self.megabitsPerSecond = megabitsPerSecond
        self.decodeMilliseconds = decodeMilliseconds
        self.drawMilliseconds = drawMilliseconds
    }

    /// Computed from the raw counters of one measurement window. `nil` if the window has no duration.
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

    /// One compact line for the statistics panel.
    public var summary: String {
        let locale = Localization.forcedLanguage.map(Locale.init(identifier:)) ?? .current
        func number(_ value: Double, _ digits: Int) -> String {
            value.formatted(.number.precision(.fractionLength(digits)).locale(locale))
        }
        var line = tr(
            "%@ fps · %@ Mbit/s · decode %@ ms · draw %@ ms",
            number(updatesPerSecond, 0), number(megabitsPerSecond, 1), number(decodeMilliseconds, 1), number(drawMilliseconds, 1)
        )
        if let pacing {
            line += " · " + tr("pacing %@/%@ ms", number(pacing.medianInterval, 0), number(pacing.p95Interval, 0))
        }
        return line
    }
}

extension Duration {
    var seconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}
