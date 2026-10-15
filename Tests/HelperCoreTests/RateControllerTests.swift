#if os(macOS)
import Foundation
@testable import HelperCore
import LinkProtocol
import Testing

private final class FakeClock: @unchecked Sendable {
    private let t = Locked(0.0)
    func advance(_ s: Double) { t.withValue { $0 += s } }
    var now: Double { t.get() }
}

/// A bottleneck link with a queue: sending more than `capacity` builds delay, then drops.
private struct SimulatedLink {
    var capacity: Double
    var baseRTT = 0.010
    var queueBits = 0.0
    mutating func tick(controller: inout RateController, clock: FakeClock, decision: RateDecision, dt: Double = 0.25) -> RateDecision {
        let sending = Double(decision.targets.reduce(0) { $0 + $1.bitrate })
        queueBits = max(0, queueBits + (sending - capacity) * dt)
        let delivered = queueBits > 0 ? capacity : min(sending, capacity)  // a standing queue means the link runs at full rate
        let queueDelay = queueBits / capacity
        let dropped = queueDelay > 0.1  // frames that arrive later than 100 ms are dropped by the client
        if dropped { queueBits = capacity * 0.05 }
        clock.advance(dt)
        var windows: [LinkWindowStats] = []
        let total = max(1, sending)
        for t in decision.targets where t.bitrate > 0 {
            windows.append(LinkWindowStats(
                window: t.window, receivedBytes: UInt64(delivered * dt / 8 * Double(t.bitrate) / total), decodedFrames: UInt32(t.framesPerSecond / 4),
                droppedFrames: dropped ? 1 : 0, decodeP95Micros: 3000))
        }
        controller.ingest(LinkStats(rttMicros: UInt32((baseRTT + queueDelay) * 1_000_000), windows: windows))
        return controller.evaluate()
    }
}

private let focusedWindow = RateWindow(id: 1, visibility: .focused, pixelWidth: 2560, pixelHeight: 1440)
private func other(_ id: UInt32, _ visibility: RateVisibility = .visible) -> RateWindow {
    RateWindow(id: WindowID(id), visibility: visibility, pixelWidth: 1600, pixelHeight: 1000)
}

private func makeController(_ clock: FakeClock, initial: Int = 40_000_000) -> RateController {
    var config = RateControllerConfig()
    config.initialCapacity = initial
    return RateController(config: config, clock: { clock.now })
}

@Suite struct RateControllerTests {
    @Test func focusedWindowGetsTheLargestShareAndOthersAreCapped() {
        let clock = FakeClock()
        var rc = makeController(clock)
        rc.setWindows([focusedWindow, other(2), other(3), other(4, .background)])
        let d = rc.evaluate()
        let byID = Dictionary(uniqueKeysWithValues: d.targets.map { ($0.window.rawValue, $0) })
        let focused = byID[1]!, a = byID[2]!, b = byID[3]!, bg = byID[4]!
        #expect(focused.bitrate > a.bitrate)
        #expect(abs(Double(focused.bitrate) - 0.6 * 40_000_000) < 1000)
        #expect(a.bitrate == b.bitrate)
        #expect(a.bitrate + b.bitrate + focused.bitrate <= 40_000_000)
        #expect(focused.framesPerSecond == 60)
        #expect((15...30).contains(a.framesPerSecond))
        #expect(bg.isPaused && bg.bitrate == 0)
        #expect(focused.forceKeyFrame && a.forceKeyFrame)  // first target of a new stream starts with an IDR
        #expect(rc.evaluate().targets.allSatisfy { !$0.forceKeyFrame })
    }

    @Test func aloneTheFocusedWindowTakesEverythingItCanUse() {
        let clock = FakeClock()
        var rc = makeController(clock, initial: 10_000_000)
        rc.setWindows([focusedWindow])
        #expect(rc.evaluate().targets[0].bitrate == 10_000_000)
    }

    @Test func focusChangeReallocates() {
        let clock = FakeClock()
        var rc = makeController(clock)
        rc.setWindows([focusedWindow, other(2)])
        _ = rc.evaluate()
        var a = other(2); a.visibility = .focused
        var b = focusedWindow; b.visibility = .visible
        rc.setWindows([b, a])
        let d = rc.evaluate()
        let t1 = d.targets.first { $0.window == 1 }!, t2 = d.targets.first { $0.window == 2 }!
        #expect(t2.bitrate > t1.bitrate)
        #expect(t2.framesPerSecond > t1.framesPerSecond || t2.framesPerSecond == 60)
        #expect((15...30).contains(t1.framesPerSecond))
    }

    @Test func capacityDropLowersBitrateWithinAFewTicks() {
        let clock = FakeClock()
        var rc = makeController(clock, initial: 30_000_000)
        rc.setWindows([focusedWindow, other(2)])
        var link = SimulatedLink(capacity: 60_000_000)
        var decision = rc.evaluate()
        for _ in 0..<12 { decision = link.tick(controller: &rc, clock: clock, decision: decision) }
        let before = decision.targets.reduce(0) { $0 + $1.bitrate }
        #expect(before >= 30_000_000)  // no congestion: not reduced, probing upwards
        link.capacity = 8_000_000
        var ticks = 0
        while ticks < 40 {
            decision = link.tick(controller: &rc, clock: clock, decision: decision)
            ticks += 1
            if decision.targets.reduce(0, { $0 + $1.bitrate }) <= 8_800_000 { break }
        }
        #expect(ticks <= 12, "took \(ticks) ticks to fit the link")
        #expect(decision.capacityBitsPerSecond >= 1_500_000)
    }

    @Test func recoversAfterTheLinkImproves() {
        let clock = FakeClock()
        var rc = makeController(clock, initial: 20_000_000)
        rc.setWindows([focusedWindow])
        var link = SimulatedLink(capacity: 5_000_000)
        var decision = rc.evaluate()
        for _ in 0..<40 { decision = link.tick(controller: &rc, clock: clock, decision: decision) }
        let low = decision.capacityBitsPerSecond
        #expect(low < 8_000_000)
        link.capacity = 50_000_000
        for _ in 0..<120 { decision = link.tick(controller: &rc, clock: clock, decision: decision) }
        #expect(decision.capacityBitsPerSecond > low * 3)
    }

    @Test func steadyLinkDoesNotCollapse() {
        let clock = FakeClock()
        var rc = makeController(clock, initial: 20_000_000)
        rc.setWindows([focusedWindow, other(2)])
        var link = SimulatedLink(capacity: 25_000_000)
        var decision = rc.evaluate()
        var minimum = Int.max
        for i in 0..<200 {
            decision = link.tick(controller: &rc, clock: clock, decision: decision)
            if i > 40 { minimum = min(minimum, decision.capacityBitsPerSecond) }
        }
        #expect(minimum > 12_000_000)
    }

    @Test func idleWindowGetsOneRefreshThenZeroFps() {
        let clock = FakeClock()
        var rc = makeController(clock)
        var idle = focusedWindow; idle.isIdle = true
        rc.setWindows([focusedWindow])
        _ = rc.evaluate()
        rc.setWindows([idle])
        let refresh = rc.evaluate().targets[0]
        #expect(refresh.refreshAtLowQP && refresh.framesPerSecond == 1 && refresh.quality == .high)
        #expect(refresh.bitrate > 1_000_000)
        let quiet = rc.evaluate().targets[0]
        #expect(quiet.isPaused && !quiet.refreshAtLowQP)
        #expect(rc.evaluate().targets[0].isPaused)
        // Activity returns: full rate again, no new IDR needed (the stream was never torn down).
        rc.setWindows([focusedWindow])
        let back = rc.evaluate().targets[0]
        #expect(back.framesPerSecond == 60 && !back.refreshAtLowQP && !back.forceKeyFrame)
        // Going idle again earns another refresh.
        rc.setWindows([idle])
        #expect(rc.evaluate().targets[0].refreshAtLowQP)
    }

    @Test func backgroundWindowsPauseAndResumeWithAKeyFrame() {
        let clock = FakeClock()
        var rc = makeController(clock)
        rc.setWindows([focusedWindow, other(2)])
        _ = rc.evaluate()
        rc.setWindows([focusedWindow, other(2, .background)])
        #expect(rc.evaluate().targets.first { $0.window == 2 }!.isPaused)
        rc.setWindows([focusedWindow, other(2)])
        let resumed = rc.evaluate().targets.first { $0.window == 2 }!
        #expect(!resumed.isPaused && resumed.forceKeyFrame)
    }

    @Test func explicitKeyFrameRequestIsOneShot() {
        let clock = FakeClock()
        var rc = makeController(clock)
        rc.setWindows([focusedWindow])
        _ = rc.evaluate()
        rc.requestKeyFrame(window: 1)
        #expect(rc.evaluate().targets[0].forceKeyFrame)
        #expect(!rc.evaluate().targets[0].forceKeyFrame)
    }

    @Test func slowDecodeLowersFrameRateNotBitrate() {
        let clock = FakeClock()
        var rc = makeController(clock)
        rc.setWindows([focusedWindow])
        let first = rc.evaluate().targets[0]
        clock.advance(0.25)
        rc.ingest(LinkStats(rttMicros: 10_000, windows: [LinkWindowStats(window: 1, receivedBytes: 1000, decodedFrames: 10, droppedFrames: 0, decodeP95Micros: 30_000)]))
        let slow = rc.evaluate().targets[0]
        #expect(slow.framesPerSecond < first.framesPerSecond)
        #expect(slow.framesPerSecond >= 15)
    }

    @Test func starvedWindowsTradeFrameRateAndQualityTier() {
        let clock = FakeClock()
        var config = RateControllerConfig()
        config.initialCapacity = 2_000_000
        var rc = RateController(config: config, clock: { clock.now })
        rc.setWindows([focusedWindow, other(2)])
        let d = rc.evaluate()
        for t in d.targets { #expect(t.framesPerSecond <= 30); #expect(t.quality == .low) }
    }

    @Test func removedWindowsLoseStateAndUnknownStatsAreIgnored() {
        let clock = FakeClock()
        var rc = makeController(clock)
        rc.setWindows([focusedWindow])
        _ = rc.evaluate()
        rc.setWindows([])
        clock.advance(0.25)
        rc.ingest(LinkStats(rttMicros: 5000, windows: [LinkWindowStats(window: 99, receivedBytes: 1, decodedFrames: 1, droppedFrames: 0, decodeP95Micros: 1)]))
        #expect(rc.evaluate().targets.isEmpty)
    }
}
#endif
