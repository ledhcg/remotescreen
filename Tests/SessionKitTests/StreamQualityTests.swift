import Foundation
import RFBKit
import Testing
@testable import SessionKit

private func stats(fps: Double = 20, mbps: Double, decode: Double = 1, draw: Double = 1) -> StreamStats {
    StreamStats(updatesPerSecond: fps, megabitsPerSecond: mbps, decodeMilliseconds: decode, drawMilliseconds: draw)
}

@Suite("QualityMode: quality modes")
struct QualityModeTests {
    @Test func defaultIsAdaptive() {
        #expect(QualityMode.default == .adaptive)
    }

    /// Every mode uses 32-bit: at 16-bit the app does not request a separate cursor image (the format is not yet measured against Apple's
    /// server), so the server draws the cursor and it moves at the frame rate, against the smoothness goal of "best performance".
    @Test func everyModeKeepsFullColourSoTheCursorStaysLocal() {
        for mode in QualityMode.allCases { #expect(mode.colorDepth == .full) }
    }

    @Test func onlyBestPerformancePrefersServerScaling() {
        #expect(QualityMode.bestPerformance.prefersServerScaling)
        #expect(!QualityMode.bestQuality.prefersServerScaling)
        #expect(!QualityMode.adaptive.prefersServerScaling)
    }

    @Test func colourDepthMapsToTheWireFormats() {
        #expect(ColorDepth.full.pixelFormat == .bgra8888)
        #expect(ColorDepth.reduced.pixelFormat == .rgb565)
        #expect(ColorDepth.reduced.pixelFormat.bitsPerPixel == 16)
    }

    @Test func frameRateCaps() {
        #expect(QualityMode.bestQuality.initialMaxFramesPerSecond == nil, "best quality must not be capped")
        #expect(QualityMode.adaptive.initialMaxFramesPerSecond == nil, "adaptive starts uncapped and steps down when heavy")
        #expect(QualityMode.bestPerformance.initialMaxFramesPerSecond == nil, "best performance favours smoothness: no frame cap")
    }

    @Test func capBecomesAnIntervalBetweenRequests() {
        #expect((20 as Int?).minimumUpdateInterval == .milliseconds(50))
        #expect((30 as Int?).minimumUpdateInterval == .nanoseconds(33_333_333))
        #expect((nil as Int?).minimumUpdateInterval == nil)
        #expect((0 as Int?).minimumUpdateInterval == .seconds(1), "a cap of 0 must not divide by zero")
    }

    @Test func modesRoundTripThroughTheirStoredName() {
        for mode in QualityMode.allCases { #expect(QualityMode(rawValue: mode.rawValue) == mode) }
        #expect(QualityMode(rawValue: "không-có") == nil, "an unknown UserDefaults value must be ignored, not crash")
    }
}

@Suite("AdaptiveGovernor: does not oscillate")
struct AdaptiveGovernorTests {
    private func feed(_ governor: inout AdaptiveGovernor, _ count: Int, _ sample: StreamStats) -> [AdaptiveGovernor.Change] {
        (0..<count).compactMap { _ in governor.observe(sample) }
    }

    @Test func startsUnlimitedAndStaysThereWhenCalm() {
        var governor = AdaptiveGovernor()
        #expect(governor.maxFramesPerSecond == nil)
        #expect(feed(&governor, 60, stats(mbps: 3)).isEmpty)
        #expect(governor.level == 0)
    }

    @Test func degradesOneStepAfterThreeHeavySeconds() {
        var governor = AdaptiveGovernor()
        #expect(governor.observe(stats(mbps: 60)) == nil)
        #expect(governor.observe(stats(mbps: 60)) == nil)
        #expect(governor.observe(stats(mbps: 60)) == .init(level: 1, maxFramesPerSecond: 30))
    }

    @Test func keepsDegradingStepByStepDownToTheLastLevel() {
        var governor = AdaptiveGovernor()
        let changes = feed(&governor, 30, stats(mbps: 80))
        #expect(changes.map(\.maxFramesPerSecond) == [30, 20, 12])
        #expect(governor.level == AdaptiveGovernor.ladder.count - 1)
        #expect(feed(&governor, 30, stats(mbps: 80)).isEmpty, "already at the last step, so no further change")
    }

    @Test func aSingleHeavySecondIsIgnored() {
        var governor = AdaptiveGovernor()
        for _ in 0..<10 {
            #expect(governor.observe(stats(mbps: 80)) == nil)
            #expect(governor.observe(stats(mbps: 80)) == nil)
            #expect(governor.observe(stats(mbps: 15)) == nil, "an in-between second restarts the count")
        }
        #expect(governor.level == 0)
    }

    @Test func restoresSlowlyAfterFifteenCalmSeconds() {
        var governor = AdaptiveGovernor()
        _ = feed(&governor, 3, stats(mbps: 80)) // down to step 1
        #expect(governor.level == 1)
        for _ in 0..<14 { #expect(governor.observe(stats(mbps: 2)) == nil) }
        #expect(governor.observe(stats(mbps: 2)) == .init(level: 0, maxFramesPerSecond: nil))
    }

    @Test func aBusyCPUAloneCountsAsHeavy() {
        // 30 updates/second, each 12 ms decode + 6 ms draw = 540 ms per second, i.e. 54% CPU, even though the network is only 5 Mbit/s.
        var governor = AdaptiveGovernor()
        let changes = feed(&governor, 3, stats(fps: 30, mbps: 5, decode: 12, draw: 6))
        #expect(changes == [.init(level: 1, maxFramesPerSecond: 30)])
    }

    @Test func anIdleStreamCountsAsCalm() {
        var governor = AdaptiveGovernor()
        _ = feed(&governor, 3, stats(mbps: 80))
        let idle = StreamStats(updatesPerSecond: 0, megabitsPerSecond: 0, decodeMilliseconds: 0, drawMilliseconds: 0)
        #expect(feed(&governor, 15, idle).count == 1, "after 15 idle seconds the full rate is restored")
    }

    @Test func capsThatAreCappedStillRestoreOnlyWhenCalmNotJustBecauseTheyAreLow() {
        // At the 12 fps step, a heavy stream held back by the cap drops to 15 Mbit/s: the in-between zone, which must NOT count as calm (or we would raise the cap and go heavy again).
        var governor = AdaptiveGovernor()
        _ = feed(&governor, 9, stats(mbps: 80)) // to the last step
        #expect(governor.level == 3)
        #expect(feed(&governor, 100, stats(fps: 12, mbps: 15)).isEmpty)
        #expect(governor.level == 3)
    }

    @Test func thresholdsAreOrderedSoThereIsAHysteresisBand() {
        #expect(AdaptiveGovernor.calmMegabits < AdaptiveGovernor.heavyMegabits)
        #expect(AdaptiveGovernor.calmBusyFraction < AdaptiveGovernor.heavyBusyFraction)
        #expect(AdaptiveGovernor.windowsToRestore > AdaptiveGovernor.windowsToDegrade)
    }
}
