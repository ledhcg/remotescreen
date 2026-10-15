import Testing
@testable import SessionKit

@Suite("FramePacing: độ đều của khung hình")
struct FramePacingTests {
    @Test func evenFramesHaveEqualMedianAndP95() throws {
        var pacing = FramePacing()
        for i in 0..<30 { pacing.recordPresent(at: Double(i) * 0.040, mergedUpdates: 1) }
        let drained = pacing.drain()
        let summary = try #require(drained)
        #expect(abs(summary.medianInterval - 40) < 0.001)
        #expect(abs(summary.p95Interval - 40) < 0.001)
        #expect(summary.updatesPerPresent == 1)
    }

    @Test func occasionalHitchesShowUpInP95NotInTheMedian() throws {
        var pacing = FramePacing()
        var t = 0.0
        for i in 0..<40 {
            t += (i % 10 == 9) ? 0.120 : 0.033
            pacing.recordPresent(at: t, mergedUpdates: i % 2 == 0 ? 2 : 1)
        }
        let drained = pacing.drain()
        let summary = try #require(drained)
        #expect(abs(summary.medianInterval - 33) < 0.5)
        #expect(summary.p95Interval > 100, "giật là thứ mắt thấy, phải lộ ra ở p95")
        #expect(summary.updatesPerPresent == 1.5)
    }

    @Test func drainStartsANewWindowButKeepsTheTimeBaseline() throws {
        var pacing = FramePacing()
        pacing.recordPresent(at: 0, mergedUpdates: 1)
        pacing.recordPresent(at: 0.05, mergedUpdates: 1)
        _ = pacing.drain()
        pacing.recordPresent(at: 0.10, mergedUpdates: 1)
        let drained = pacing.drain()
        let summary = try #require(drained)
        #expect(abs(summary.medianInterval - 50) < 0.001, "khoảng đầu cửa sổ mới tính từ lần hiện cuối của cửa sổ trước")
    }

    @Test func aWindowWithoutTwoPresentsHasNoSummary() {
        var pacing = FramePacing()
        let empty = pacing.drain()
        #expect(empty == nil)
        pacing.recordPresent(at: 1, mergedUpdates: 1)
        let single = pacing.drain()
        #expect(single == nil)
    }

    @Test func resettingTheBaselineHidesIdleGaps() throws {
        var pacing = FramePacing()
        pacing.recordPresent(at: 0, mergedUpdates: 1)
        pacing.resetBaseline()
        pacing.recordPresent(at: 10, mergedUpdates: 1)
        pacing.recordPresent(at: 10.04, mergedUpdates: 1)
        let drained = pacing.drain()
        let summary = try #require(drained)
        #expect(summary.p95Interval < 50, "10 giây đứng yên không phải là giật")
    }
}
