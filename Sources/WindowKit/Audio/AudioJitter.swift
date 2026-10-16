import Foundation

/// Estimates network jitter of the audio stream and turns it into a playout buffer target of 20 to 40 ms.
///
/// The estimate is the RFC 3550 interarrival jitter: for consecutive packets, `D = (arrival gap) - (timestamp gap)`, and the
/// estimate moves by 1/16 of the distance to `|D|`. Pure and allocation-free; time comes from the caller.
public struct JitterEstimator: Sendable, Equatable {
    public static let minTargetMillis = 20.0
    public static let maxTargetMillis = 40.0
    /// Target = `minTargetMillis` + this many times the jitter estimate.
    static let jitterMultiplier = 4.0
    /// A single gap beyond this is a pause or a restart, not jitter.
    static let outlierSeconds = 0.5

    public private(set) var jitterSeconds = 0.0
    private var lastArrival: Double?
    private var lastPTSMicros: UInt64?

    public init() {}

    /// Feeds one packet: when it arrived (seconds, monotonic) and the sender's timestamp for it.
    public mutating func record(arrival: Double, ptsMicros: UInt64) {
        defer { lastArrival = arrival; lastPTSMicros = ptsMicros }
        guard arrival.isFinite, let lastArrival, let lastPTSMicros, ptsMicros > lastPTSMicros else { return }
        let arrivalGap = arrival - lastArrival
        let sendGap = Double(ptsMicros - lastPTSMicros) / 1_000_000
        let deviation = abs(arrivalGap - sendGap)
        if arrivalGap < 0 || deviation > Self.outlierSeconds {
            // The clock went backwards, or the stream paused and resumed: start over instead of poisoning the estimate.
            jitterSeconds = 0
            return
        }
        jitterSeconds += (deviation - jitterSeconds) / 16
    }

    public mutating func reset() { self = JitterEstimator() }

    /// The buffer to hold before playing, in milliseconds, always within 20...40.
    public var targetMillis: Double {
        min(max(Self.minTargetMillis + Self.jitterMultiplier * jitterSeconds * 1000, Self.minTargetMillis), Self.maxTargetMillis)
    }
}

/// Decides how many single frames to drop (positive) or repeat (negative) while rendering, so the buffer drifts back to its target
/// when the sender's clock and the device's clock disagree. Corrections are rare (at most one frame per `framesPerAdjustment`
/// rendered, 0.2% at 48 kHz) and only start outside a dead band, so they are inaudible.
public struct DriftPolicy: Sendable, Equatable {
    public var framesPerAdjustment: Int
    /// No correction while the buffer is within this many frames of the target.
    public var deadbandFrames: Int
    private var rendered = 0

    public init(sampleRate: Int) {
        framesPerAdjustment = max(sampleRate / 100, 1)  // 10 ms
        deadbandFrames = max(sampleRate * 4 / 1000, 1)  // 4 ms
    }

    /// Frames to drop (> 0) or insert (< 0) in a render of `renderFrames`.
    public mutating func correction(bufferedFrames: Int, targetFrames: Int, renderFrames: Int) -> Int {
        rendered += max(renderFrames, 0)
        let allowed = rendered / framesPerAdjustment
        guard allowed > 0 else { return 0 }
        rendered -= allowed * framesPerAdjustment
        let error = bufferedFrames - targetFrames
        if error > deadbandFrames { return min(allowed, (error - deadbandFrames) + 1, max(renderFrames - 1, 0)) }
        if error < -deadbandFrames { return -min(allowed, (-error - deadbandFrames) + 1, max(renderFrames - 1, 0)) }
        return 0
    }

    public mutating func reset() { rendered = 0 }
}
