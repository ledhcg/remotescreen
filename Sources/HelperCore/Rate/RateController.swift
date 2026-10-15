#if os(macOS)
import Foundation
import LinkProtocol

/// How much of the user's attention a streamed window has.
public enum RateVisibility: Sendable, Equatable {
    /// The window of the focused scene on the iPad.
    case focused
    /// On screen on the iPad but not focused (Split View / Stage Manager neighbours).
    case visible
    /// Not shown on the iPad (scene in the background): no video at all.
    case background
}

/// What the controller needs to know about one streamed window.
public struct RateWindow: Sendable, Equatable {
    public var id: WindowID
    public var visibility: RateVisibility
    /// The capture engine reported no changes (see `CaptureEvent.idle`).
    public var isIdle: Bool
    public var pixelWidth: UInt32
    public var pixelHeight: UInt32
    /// The subscriber's `maxFramesPerSecond`.
    public var requestedFramesPerSecond: Int
    public var requestedQuality: LinkQualityTier
    public init(
        id: WindowID, visibility: RateVisibility, isIdle: Bool = false, pixelWidth: UInt32, pixelHeight: UInt32,
        requestedFramesPerSecond: Int = 60, requestedQuality: LinkQualityTier = .high
    ) {
        self.id = id; self.visibility = visibility; self.isIdle = isIdle; self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight; self.requestedFramesPerSecond = requestedFramesPerSecond; self.requestedQuality = requestedQuality
    }
}

/// What to configure the encoder (and the capture frame rate) with for one window.
public struct WindowTarget: Sendable, Equatable {
    public var window: WindowID
    /// Bits per second. 0 when paused.
    public var bitrate: Int
    /// 0 when paused: the capture and encode of this window should stop.
    public var framesPerSecond: Int
    public var quality: LinkQualityTier
    /// Send an IDR next (window returned from the background, or `requestKeyFrame` was called).
    public var forceKeyFrame: Bool
    /// One-shot: the window just went idle, so encode one frame at low QP (high bitrate for a single frame) so text is
    /// sharp, then stay at 0 fps. `bitrate` holds the burst rate for that frame.
    public var refreshAtLowQP: Bool
    public var isPaused: Bool { framesPerSecond == 0 }
}

public struct RateDecision: Sendable, Equatable {
    public var targets: [WindowTarget]
    /// The controller's current estimate of usable link capacity.
    public var capacityBitsPerSecond: Int
    public var isCongested: Bool
}

public struct RateControllerConfig: Sendable {
    public var initialCapacity = 20_000_000
    public var minCapacity = 1_500_000
    public var maxCapacity = 200_000_000
    /// Share of the capacity given to the focused window while other windows are active.
    public var focusShare = 0.6
    public var maxFocusedFramesPerSecond = 60
    public var visibleFramesPerSecondRange = 15...30
    /// Multiplicative decrease on congestion.
    public var decreaseFactor = 0.85
    /// Minimum time between two decreases.
    public var decreaseCooldown = 0.5
    /// After congestion, wait this long before probing upwards again.
    public var increaseHold = 1.0
    /// Additive increase per statistics report, as a fraction of the capacity.
    public var increaseStep = 0.04
    /// Queueing delay above `rttSlack + baseRTT * rttSlackRatio` counts as congestion.
    public var rttSlack = 0.020
    public var rttSlackRatio = 0.25
    public var minWindowBitrate = 300_000
    /// Bits per pixel per frame above which more bitrate brings nothing (keeps a static 5K window from taking everything).
    public var maxBitsPerPixel = 0.5
    /// Burst rate of the single idle refresh frame.
    public var refreshBitrate = 16_000_000
    public init() {}
}

/// Chooses per-window bitrate, frame rate and quality from the iPad's periodic statistics.
///
/// Pure and deterministic: time comes from the injected `clock` (seconds, monotonic), and no VideoToolbox or network type
/// appears here. Statistics fields are read as **per-report deltas** (`receivedBytes`, `decodedFrames` and `droppedFrames`
/// count what happened since the previous 250 ms report).
public struct RateController: Sendable {
    private struct WindowState {
        var isIdleHandled = false
        var wasPaused = true
        var forceKey = false
        /// Frame rate ceiling from slow decoding; nil = none.
        var decodeCap: Int?
        var lastFps = 0
    }

    public let config: RateControllerConfig
    private let clock: @Sendable () -> Double
    private var windows: [WindowID: RateWindow] = [:]
    private var states: [WindowID: WindowState] = [:]
    private var capacity: Double
    private var baseRTT: Double?
    private var lastStatsAt: Double?
    private var lastDecreaseAt = -Double.infinity
    private var lastCongestedAt = -Double.infinity
    private var receiveRate = 0.0  // smoothed, bits per second
    private var lastAllocated = 0.0
    private var congested = false

    public init(config: RateControllerConfig = RateControllerConfig(), clock: @escaping @Sendable () -> Double) {
        self.config = config; self.clock = clock
        capacity = Double(config.initialCapacity)
    }

    public var capacityBitsPerSecond: Int { Int(capacity) }

    // MARK: Inputs

    /// Replaces the set of streamed windows. Windows that disappear lose their state.
    public mutating func setWindows(_ list: [RateWindow]) {
        windows = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        states = states.filter { windows[$0.key] != nil }
        for id in windows.keys where states[id] == nil { states[id] = WindowState() }
    }

    /// The next target for this window will carry `forceKeyFrame` (new subscriber, decode error, scene restored).
    public mutating func requestKeyFrame(window: WindowID) { states[window]?.forceKey = true }

    /// Feeds one `stats` report. Updates the capacity estimate (AIMD on queueing delay and drops).
    public mutating func ingest(_ stats: LinkStats) {
        let now = clock()
        let dt = min(max(now - (lastStatsAt ?? now - 0.25), 0.05), 2.0)
        lastStatsAt = now

        var bytes: UInt64 = 0
        var drops: UInt64 = 0
        for w in stats.windows {
            bytes &+= w.receivedBytes
            drops &+= UInt64(w.droppedFrames)
            updateDecodeCap(w)
        }
        let instant = Double(bytes) * 8 / dt
        receiveRate = receiveRate == 0 ? instant : receiveRate * 0.5 + instant * 0.5

        let rtt = Double(stats.rttMicros) / 1_000_000
        if rtt > 0 { baseRTT = min(baseRTT ?? rtt, rtt) }
        let queueing = max(0, rtt - (baseRTT ?? rtt))
        let rttSignal = queueing > config.rttSlack + (baseRTT ?? 0) * config.rttSlackRatio
        congested = rttSignal || drops > 0

        if congested {
            lastCongestedAt = now
            if now - lastDecreaseAt >= config.decreaseCooldown {
                lastDecreaseAt = now
                // If the link delivered less than we sent, what arrived is the best capacity estimate.
                let observed = receiveRate > 0 && receiveRate < lastAllocated * 0.95 ? receiveRate * 0.9 : capacity
                let floor = capacity * 0.5
                capacity = max(Double(config.minCapacity), max(floor, min(capacity * config.decreaseFactor, observed)))
            }
        } else if now - lastCongestedAt >= config.increaseHold, lastAllocated == 0 || receiveRate >= lastAllocated * 0.6 {
            // Probe upwards only while the current allocation is actually being used.
            capacity = min(Double(config.maxCapacity), capacity + max(100_000, capacity * config.increaseStep))
        }
    }

    private mutating func updateDecodeCap(_ w: LinkWindowStats) {
        guard var state = states[w.window], let window = windows[w.window], state.lastFps > 0 else { return }
        let budgetMicros = 1_000_000 / Double(state.lastFps)
        if Double(w.decodeP95Micros) > budgetMicros * 0.9 {
            state.decodeCap = max(15, Int(Double(state.lastFps) * 0.75))
        } else if let cap = state.decodeCap, Double(w.decodeP95Micros) < budgetMicros * 0.5 {
            let raised = cap + 5
            state.decodeCap = raised >= window.requestedFramesPerSecond ? nil : raised
        }
        states[w.window] = state
    }

    // MARK: Output

    /// Computes the targets. One-shot flags (`forceKeyFrame`, `refreshAtLowQP`) are consumed by this call.
    public mutating func evaluate() -> RateDecision {
        var targets: [WindowTarget] = []
        let ordered = windows.values.sorted { $0.id < $1.id }

        // Which windows get video now.
        var active: [RateWindow] = []
        var refreshing: [WindowID] = []
        for w in ordered {
            var state = states[w.id] ?? WindowState()
            defer { states[w.id] = state }
            if w.visibility == .background {
                state.isIdleHandled = false
                continue
            }
            if w.isIdle {
                if !state.isIdleHandled { state.isIdleHandled = true; refreshing.append(w.id) }
                continue
            }
            state.isIdleHandled = false
            active.append(w)
        }

        let focused = active.first { $0.visibility == .focused }
        let others = active.filter { $0.visibility != .focused }
        var share: [WindowID: Double] = [:]
        if let focused {
            share[focused.id] = others.isEmpty ? capacity : capacity * config.focusShare
            let rest = others.isEmpty ? 0 : capacity * (1 - config.focusShare) / Double(others.count)
            for o in others { share[o.id] = rest }
        } else if !others.isEmpty {
            for o in others { share[o.id] = capacity / Double(others.count) }
        }

        // Cap each window at what its pixels can use; hand the surplus to windows that are not capped.
        var fpsFor: [WindowID: Int] = [:]
        for w in active { fpsFor[w.id] = framesPerSecond(for: w) }
        var surplus = 0.0
        var uncapped: [WindowID] = []
        for w in active {
            let cap = Double(w.pixelWidth) * Double(w.pixelHeight) * Double(fpsFor[w.id] ?? 1) * config.maxBitsPerPixel
            if let s = share[w.id], s > cap { surplus += s - cap; share[w.id] = cap } else { uncapped.append(w.id) }
        }
        if surplus > 0, !uncapped.isEmpty {
            let each = surplus / Double(uncapped.count)
            for id in uncapped { share[id, default: 0] += each }
        }

        var allocated = 0.0
        for w in ordered {
            var state = states[w.id] ?? WindowState()
            if let bits = share[w.id] {
                var fps = fpsFor[w.id] ?? 1
                let pixels = max(1, Double(w.pixelWidth) * Double(w.pixelHeight))
                var bitrate = max(Double(config.minWindowBitrate), bits)
                var bpp = bitrate / (pixels * Double(fps))
                // Starved: trade frame rate for quality before blocking up the picture.
                if bpp < 0.02, fps > 30 { fps = 30; bpp = bitrate / (pixels * Double(fps)) }
                if bpp < 0.012, fps > 15 { fps = 15; bpp = bitrate / (pixels * Double(fps)) }
                bitrate = max(bitrate, 0)
                let derived: LinkQualityTier = bpp < 0.03 ? .low : (bpp < 0.08 ? .balanced : .high)
                let quality = LinkQualityTier(rawValue: min(derived.rawValue, w.requestedQuality.rawValue)) ?? derived
                targets.append(WindowTarget(
                    window: w.id, bitrate: Int(bitrate), framesPerSecond: fps, quality: quality,
                    forceKeyFrame: state.forceKey || state.wasPaused, refreshAtLowQP: false))
                allocated += bitrate
                state.forceKey = false; state.wasPaused = false; state.lastFps = fps
            } else if refreshing.contains(w.id) {
                // The window just went idle: one sharp frame, then silence.
                targets.append(WindowTarget(
                    window: w.id, bitrate: min(config.refreshBitrate, Int(capacity * 0.5)), framesPerSecond: 1, quality: .high,
                    forceKeyFrame: state.forceKey, refreshAtLowQP: true))
                state.forceKey = false; state.lastFps = 1
            } else {
                targets.append(WindowTarget(window: w.id, bitrate: 0, framesPerSecond: 0, quality: .low, forceKeyFrame: false, refreshAtLowQP: false))
                // A keyframe request made while paused waits for the window to wake up.
                state.wasPaused = w.visibility == .background || state.wasPaused
                state.lastFps = 0
            }
            states[w.id] = state
        }
        lastAllocated = allocated
        return RateDecision(targets: targets, capacityBitsPerSecond: Int(capacity), isCongested: congested)
    }

    private func framesPerSecond(for w: RateWindow) -> Int {
        let requested = max(1, min(w.requestedFramesPerSecond, Int(LinkLimits.maxFramesPerSecond)))
        var fps: Int
        if w.visibility == .focused {
            fps = min(requested, config.maxFocusedFramesPerSecond)
        } else {
            let range = config.visibleFramesPerSecondRange
            fps = min(requested, range.upperBound)
            if requested >= range.lowerBound { fps = max(fps, range.lowerBound) }
        }
        if let cap = states[w.id]?.decodeCap { fps = min(fps, max(cap, 1)) }
        return fps
    }
}
#endif
