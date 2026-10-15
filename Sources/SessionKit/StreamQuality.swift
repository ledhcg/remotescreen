import Foundation
import RFBKit

/// Colour depth requested from the server. Chosen at **connect** time (changing it mid-session changes the pixel format while
/// updates are in flight, and RFB has no marker saying which update uses which format, so the app reconnects instead of guessing).
public enum ColorDepth: Sendable, Equatable {
    /// 32-bit, lossless colour.
    case full
    /// 16-bit (5-6-5): on a real Mac a full frame shrinks to about 51% of its size and a motion stream to 65-71%. Apple's server does
    /// not accept 8-bit.
    case reduced

    public var pixelFormat: PixelFormat { self == .full ? .bgra8888 : .rgb565 }
}

/// Quality mode chosen by the user, like the Adaptive/Full Quality options of Screen Sharing plus a "best performance" option.
public enum QualityMode: String, CaseIterable, Sendable {
    /// Full colour; the app lowers the frame rate when the stream is heavy (network or CPU) and raises it again when light.
    case adaptive
    /// Full colour, the highest frame rate possible.
    case bestQuality
    /// Prioritises **smoothness**: no frame cap, the cursor is always drawn locally, and for a Mac the server scales the image down to
    /// the viewport resolution (fewer pixels to compress and send).
    ///
    /// This mode used to be 16-bit with a 20 fps cap: it saved bandwidth but was less smooth (measured on iPad: 17 fps versus 25),
    /// and at 16-bit the server draws the cursor into the frame, so the cursor moved at the frame rate. 16-bit only returns once we
    /// measure how Apple's server sends the cursor image at 16-bit (to keep the cursor local); see `ColorDepth`.
    case bestPerformance

    public static let `default` = QualityMode.adaptive

    /// Colour depth of the mode. Does not change during a session (see `ColorDepth`).
    public var colorDepth: ColorDepth { .full }

    /// Ask Apple's server to scale the image down to the viewport resolution (message type 8), regardless of display mode.
    public var prefersServerScaling: Bool { self == .bestPerformance }

    /// Initial frame cap: `nil` means unlimited. With `.adaptive`, `AdaptiveGovernor` changes this value according to load.
    public var initialMaxFramesPerSecond: Int? { nil }
}

extension Optional where Wrapped == Int {
    /// Minimum spacing between two update requests for the given frame cap.
    public var minimumUpdateInterval: Duration? {
        map { .nanoseconds(1_000_000_000 / Swift.max($0, 1)) }
    }
}

/// Controller for `.adaptive` mode: watches the per-second statistics of the stream and decides whether to lower or raise the frame cap.
///
/// Designed **not to oscillate**: it lowers quickly (3 heavy seconds in a row) but raises slowly (15 calm seconds in a row), one step at
/// a time, and a single "in-between" second restarts the count. The frame cap is the only knob it turns, since colour depth cannot
/// change mid-session (see `ColorDepth`).
public struct AdaptiveGovernor: Sendable, Equatable {
    /// The steps, from fastest to most economical.
    public static let ladder: [Int?] = [nil, 30, 20, 12]

    /// Heavy: >= 30 Mbit/s (ordinary Wi-Fi cannot sustain it for long), or the CPU spends >= 45% of its time decoding and drawing.
    public static let heavyMegabits = 30.0
    public static let heavyBusyFraction = 0.45
    /// Calm: <= 10 Mbit/s and CPU <= 15%. Between the two thresholds is the in-between zone: neither lower nor raise.
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

    /// Fraction of CPU time spent on the stream in the window: (decode + draw) per update × updates per second.
    static func busyFraction(_ stats: StreamStats) -> Double {
        (stats.decodeMilliseconds + stats.drawMilliseconds) * stats.updatesPerSecond / 1000
    }

    /// Takes the statistics of one window (about one second). Returns a change if the frame cap needs to change.
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
