import Foundation
import RFBKit
import Testing
@testable import SessionKit

private func stats(fps: Double = 20, mbps: Double, decode: Double = 1, draw: Double = 1) -> StreamStats {
    StreamStats(updatesPerSecond: fps, megabitsPerSecond: mbps, decodeMilliseconds: decode, drawMilliseconds: draw)
}

@Suite("QualityMode: chế độ chất lượng")
struct QualityModeTests {
    @Test func defaultIsAdaptive() {
        #expect(QualityMode.default == .adaptive)
    }

    /// Mọi chế độ dùng 32 bit: ở 16 bit app không xin hình con trỏ riêng (định dạng chưa đo được với server Apple), nên con
    /// trỏ do server vẽ và nhích theo nhịp khung, ngược với mục tiêu mượt của "hiệu năng tốt nhất".
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
        #expect(QualityMode.bestQuality.initialMaxFramesPerSecond == nil, "hiển thị tốt nhất không được giới hạn")
        #expect(QualityMode.adaptive.initialMaxFramesPerSecond == nil, "tự động bắt đầu không giới hạn, hạ khi nặng")
        #expect(QualityMode.bestPerformance.initialMaxFramesPerSecond == nil, "hiệu năng tốt nhất ưu tiên mượt: không có trần khung hình")
    }

    @Test func capBecomesAnIntervalBetweenRequests() {
        #expect((20 as Int?).minimumUpdateInterval == .milliseconds(50))
        #expect((30 as Int?).minimumUpdateInterval == .nanoseconds(33_333_333))
        #expect((nil as Int?).minimumUpdateInterval == nil)
        #expect((0 as Int?).minimumUpdateInterval == .seconds(1), "trần 0 không được chia cho 0")
    }

    @Test func modesRoundTripThroughTheirStoredName() {
        for mode in QualityMode.allCases { #expect(QualityMode(rawValue: mode.rawValue) == mode) }
        #expect(QualityMode(rawValue: "không-có") == nil, "giá trị lạ trong UserDefaults phải bị bỏ, không sập")
    }
}

@Suite("AdaptiveGovernor: không dao động")
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
        #expect(feed(&governor, 30, stats(mbps: 80)).isEmpty, "đã ở bậc cuối thì không đổi nữa")
    }

    @Test func aSingleHeavySecondIsIgnored() {
        var governor = AdaptiveGovernor()
        for _ in 0..<10 {
            #expect(governor.observe(stats(mbps: 80)) == nil)
            #expect(governor.observe(stats(mbps: 80)) == nil)
            #expect(governor.observe(stats(mbps: 15)) == nil, "một giây lưng chừng chen vào thì đếm lại")
        }
        #expect(governor.level == 0)
    }

    @Test func restoresSlowlyAfterFifteenCalmSeconds() {
        var governor = AdaptiveGovernor()
        _ = feed(&governor, 3, stats(mbps: 80)) // xuống bậc 1
        #expect(governor.level == 1)
        for _ in 0..<14 { #expect(governor.observe(stats(mbps: 2)) == nil) }
        #expect(governor.observe(stats(mbps: 2)) == .init(level: 0, maxFramesPerSecond: nil))
    }

    @Test func aBusyCPUAloneCountsAsHeavy() {
        // 30 cập nhật/giây, mỗi cái 12 ms giải mã + 6 ms vẽ = 540 ms mỗi giây, tức 54% CPU, dù mạng chỉ 5 Mbit/s.
        var governor = AdaptiveGovernor()
        let changes = feed(&governor, 3, stats(fps: 30, mbps: 5, decode: 12, draw: 6))
        #expect(changes == [.init(level: 1, maxFramesPerSecond: 30)])
    }

    @Test func anIdleStreamCountsAsCalm() {
        var governor = AdaptiveGovernor()
        _ = feed(&governor, 3, stats(mbps: 80))
        let idle = StreamStats(updatesPerSecond: 0, megabitsPerSecond: 0, decodeMilliseconds: 0, drawMilliseconds: 0)
        #expect(feed(&governor, 15, idle).count == 1, "màn hình đứng yên 15 giây thì trả lại tốc độ đầy đủ")
    }

    @Test func capsThatAreCappedStillRestoreOnlyWhenCalmNotJustBecauseTheyAreLow() {
        // Ở bậc 12 khung/s, luồng nặng bị trần kìm lại còn 15 Mbit/s: vùng lưng chừng, KHÔNG được coi là nhẹ để nâng lên rồi lại nặng.
        var governor = AdaptiveGovernor()
        _ = feed(&governor, 9, stats(mbps: 80)) // tới bậc cuối
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
