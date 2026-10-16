import Foundation
import os

/// Counters for diagnostics ("glitch counter"). All are totals since the playout was created or `reset`.
public struct AudioPlayoutStats: Sendable, Equatable {
    /// The buffer ran dry while playing (an audible gap, faded).
    public var underruns = 0
    /// Buffered audio was thrown away because the buffer was far above its target or full.
    public var overflows = 0
    /// Single frames dropped / repeated by drift correction (inaudible by design).
    public var droppedFrames = 0
    public var insertedFrames = 0
    public var playedFrames = 0
    public var bufferedMillis = 0.0
    public var targetMillis = 0.0

    public init() {}

    /// Underruns and overflows: what the person can hear.
    public var glitches: Int { underruns + overflows }
}

/// A fixed-size ring of interleaved 16-bit frames. Not thread safe by itself; `AudioPlayout` serialises access.
/// Storage is allocated once in `init`, so reading and writing never allocate.
struct AudioRing {
    let channels: Int
    let capacityFrames: Int
    private let storage: UnsafeMutablePointer<Int16>
    private var head = 0  // oldest frame
    private(set) var count = 0

    init(channels: Int, capacityFrames: Int) {
        self.channels = channels
        self.capacityFrames = capacityFrames
        storage = .allocate(capacity: channels * capacityFrames)
        storage.initialize(repeating: 0, count: channels * capacityFrames)
    }

    func deallocate() { storage.deallocate() }

    var availableFrames: Int { count }

    /// Appends little-endian frames. When the ring is full the oldest frames are dropped (newest audio wins). Returns the number
    /// of frames dropped to make room.
    @discardableResult
    mutating func write(littleEndian bytes: UnsafeRawBufferPointer) -> Int {
        let frameBytes = channels * 2
        var frames = bytes.count / frameBytes
        var source = 0
        var dropped = 0
        if frames > capacityFrames {  // keep the tail of an oversized write
            let skip = frames - capacityFrames
            source = skip * frameBytes
            frames = capacityFrames
            dropped += skip
        }
        let overflow = count + frames - capacityFrames
        if overflow > 0 {
            discard(overflow)
            dropped += overflow
        }
        var tail = (head + count) % capacityFrames
        for _ in 0..<frames {
            let base = tail * channels
            for c in 0..<channels {
                storage[base + c] = Int16(littleEndian: bytes.loadUnaligned(fromByteOffset: source + c * 2, as: Int16.self))
            }
            source += frameBytes
            tail += 1
            if tail == capacityFrames { tail = 0 }
        }
        count += frames
        return dropped
    }

    /// Moves up to `frames` frames into `out` (interleaved). Returns how many were moved.
    @discardableResult
    mutating func read(into out: UnsafeMutablePointer<Int16>, frames: Int) -> Int {
        let n = min(max(frames, 0), count)
        var index = head
        for f in 0..<n {
            let base = index * channels
            for c in 0..<channels { out[f * channels + c] = storage[base + c] }
            index += 1
            if index == capacityFrames { index = 0 }
        }
        head = index
        count -= n
        if count == 0 { head = 0 }
        return n
    }

    mutating func discard(_ frames: Int) {
        let n = min(max(frames, 0), count)
        head = (head + n) % capacityFrames
        count -= n
    }

    mutating func clear() { head = 0; count = 0 }
}

/// The playout side of audio: a jitter buffer feeding a render callback.
///
/// - `push` (network thread) appends 16-bit little-endian PCM and feeds the jitter estimator, which sets a 20 to 40 ms target.
/// - `render` (audio thread) fills the output. It waits until the target is buffered before it starts, corrects clock drift by
///   dropping or repeating single frames, and on underrun fades out and goes silent until the target is buffered again.
/// - Both calls take one unfair lock for a few microseconds and never allocate.
public final class AudioPlayout: @unchecked Sendable {
    /// Length of the fade at an underrun or a restart, in milliseconds.
    static let fadeMillis = 2

    private struct State {
        var ring: AudioRing
        var jitter = JitterEstimator()
        var drift: DriftPolicy
        var stats = AudioPlayoutStats()
        var playing = false
        var fadeInRemaining = 0
        var muted = false
        var targetFrames: Int
    }

    public let sampleRate: Int
    public let channels: Int
    private let state: OSAllocatedUnfairLock<State>
    private let fadeFrames: Int
    /// Bigger than this above the target is thrown away at once instead of being drained slowly.
    private let hardTrimMarginFrames: Int
    private let minTargetFrames: Int

    /// - Parameter capacityMillis: size of the ring. Audio beyond it replaces the oldest.
    public init(sampleRate: Int, channels: Int, capacityMillis: Int = 250) {
        precondition(sampleRate > 0 && channels > 0 && channels <= 8)
        self.sampleRate = sampleRate
        self.channels = channels
        fadeFrames = max(sampleRate * Self.fadeMillis / 1000, 1)
        hardTrimMarginFrames = sampleRate * 40 / 1000
        minTargetFrames = Int(JitterEstimator.minTargetMillis) * sampleRate / 1000
        let capacity = max(sampleRate * capacityMillis / 1000, 1)
        state = OSAllocatedUnfairLock(uncheckedState: State(
            ring: AudioRing(channels: channels, capacityFrames: capacity), drift: DriftPolicy(sampleRate: sampleRate),
            targetFrames: Int(JitterEstimator.minTargetMillis) * sampleRate / 1000))
    }

    deinit { state.withLockUnchecked { $0.ring.deallocate() } }

    // MARK: Network side

    /// Adds one packet of interleaved little-endian 16-bit PCM. Ignored while muted. A length that is not a whole number of frames
    /// is truncated to whole frames.
    public func push(_ pcm: Data, ptsMicros: UInt64, arrival: Double) {
        pcm.withUnsafeBytes { bytes in
            state.withLockUnchecked { state in
                guard !state.muted else { return }
                state.jitter.record(arrival: arrival, ptsMicros: ptsMicros)
                let target = Int(state.jitter.targetMillis * Double(sampleRate) / 1000)
                // Follow the estimate in steps of 2 ms or more, so the target does not wobble.
                if abs(target - state.targetFrames) >= sampleRate * 2 / 1000 { state.targetFrames = target }
                if state.ring.write(littleEndian: bytes) > 0 { state.stats.overflows += 1 }
            }
        }
    }

    /// Mutes (the window's scene is in the background): buffered audio is dropped and packets are ignored until unmuted.
    public func setMuted(_ muted: Bool) {
        state.withLockUnchecked { state in
            guard state.muted != muted else { return }
            state.muted = muted
            if muted { Self.stop(&state) }
        }
    }

    /// Forgets everything buffered and learned (a new `audio.config`).
    public func reset() {
        state.withLockUnchecked { state in
            Self.stop(&state)
            state.jitter.reset()
            state.targetFrames = minTargetFrames
            state.drift.reset()
        }
    }

    private static func stop(_ state: inout State) {
        state.ring.clear()
        state.playing = false
        state.fadeInRemaining = 0
    }

    public var stats: AudioPlayoutStats {
        state.withLockUnchecked { state in
            var result = state.stats
            result.bufferedMillis = Double(state.ring.availableFrames) * 1000 / Double(sampleRate)
            result.targetMillis = Double(state.targetFrames) * 1000 / Double(sampleRate)
            return result
        }
    }

    // MARK: Audio thread

    /// Fills `out` with `frames` interleaved frames. Always writes every sample (silence when there is nothing to play).
    public func render(into out: UnsafeMutablePointer<Int16>, frames: Int) {
        guard frames > 0 else { return }
        let channels = self.channels
        state.withLockUnchecked { state in
            let total = frames * channels
            guard !state.muted else { out.update(repeating: 0, count: total); return }

            if !state.playing {
                if state.ring.availableFrames >= state.targetFrames {
                    state.playing = true
                    state.fadeInRemaining = fadeFrames
                    state.drift.reset()
                } else {
                    out.update(repeating: 0, count: total)
                    return
                }
            }

            // A burst left far more than the target buffered: drop the excess at once.
            let ceiling = state.targetFrames + hardTrimMarginFrames
            if state.ring.availableFrames > ceiling {
                state.ring.discard(state.ring.availableFrames - state.targetFrames)
                state.stats.overflows += 1
            }

            let correction = state.drift.correction(
                bufferedFrames: state.ring.availableFrames, targetFrames: state.targetFrames, renderFrames: frames)
            var produced = 0
            if correction == 0 {
                produced = state.ring.read(into: out, frames: frames)
            } else {
                // Spread single-frame drops/repeats evenly over the render.
                let steps = abs(correction)
                let segment = max(frames / (steps + 1), 1)
                var applied = 0
                while produced < frames {
                    let want = min(segment, frames - produced)
                    let got = state.ring.read(into: out + produced * channels, frames: want)
                    produced += got
                    if got < want { break }
                    if applied < steps, produced < frames {
                        applied += 1
                        if correction > 0 {
                            state.ring.discard(1)
                            state.stats.droppedFrames += 1
                        } else {
                            // Repeat the frame just written.
                            let last = (produced - 1) * channels
                            for c in 0..<channels { out[produced * channels + c] = out[last + c] }
                            produced += 1
                            state.stats.insertedFrames += 1
                        }
                    }
                }
            }

            if state.fadeInRemaining > 0 {
                let n = min(state.fadeInRemaining, produced)
                let start = fadeFrames - state.fadeInRemaining
                for f in 0..<n {
                    let gain = Float(start + f + 1) / Float(fadeFrames)
                    for c in 0..<channels { out[f * channels + c] = Int16(Float(out[f * channels + c]) * gain) }
                }
                state.fadeInRemaining -= n
            }

            if produced < frames {
                // Ran dry: fade the tail of what we have to zero, fill the rest with silence, wait for the target again.
                let n = min(fadeFrames, produced)
                for f in 0..<n {
                    let index = produced - n + f
                    let gain = Float(n - f - 1) / Float(n)
                    for c in 0..<channels { out[index * channels + c] = Int16(Float(out[index * channels + c]) * gain) }
                }
                (out + produced * channels).update(repeating: 0, count: (frames - produced) * channels)
                state.playing = false
                state.stats.underruns += 1
            }
            state.stats.playedFrames += produced
        }
    }
}
