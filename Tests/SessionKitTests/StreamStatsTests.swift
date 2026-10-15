import Foundation
import Testing
@testable import SessionKit

@Suite("StreamStats")
struct StreamStatsTests {
    @Test func computesRatesAndPerUpdateAverages() throws {
        // 18 cập nhật trong 1 s, 800 000 byte (6,4 Mbit), giải mã 72 ms (4 ms mỗi cập nhật), vẽ 54 ms (3 ms).
        let stats = try #require(StreamStats.measure(
            updates: 18, wireBytes: 800_000, decode: .milliseconds(72), draw: .milliseconds(54), over: .seconds(1)
        ))
        #expect(stats.updatesPerSecond == 18)
        #expect(abs(stats.megabitsPerSecond - 6.4) < 1e-9)
        #expect(abs(stats.decodeMilliseconds - 4) < 1e-9)
        #expect(abs(stats.drawMilliseconds - 3) < 1e-9)
    }

    @Test func ratesScaleWithTheWindowLength() throws {
        let stats = try #require(StreamStats.measure(updates: 10, wireBytes: 1_000_000, decode: .zero, draw: .zero, over: .seconds(2)))
        #expect(stats.updatesPerSecond == 5)
        #expect(abs(stats.megabitsPerSecond - 4) < 1e-9)
    }

    @Test func anIdleWindowReportsZerosNotNaN() throws {
        let stats = try #require(StreamStats.measure(updates: 0, wireBytes: 0, decode: .zero, draw: .zero, over: .seconds(1)))
        #expect(stats.updatesPerSecond == 0)
        #expect(stats.decodeMilliseconds == 0 && stats.drawMilliseconds == 0)
        #expect(!stats.summary.contains("nan"))
    }

    @Test func aWindowWithoutDurationHasNoStats() {
        #expect(StreamStats.measure(updates: 1, wireBytes: 1, decode: .zero, draw: .zero, over: .zero) == nil)
    }

    @Test func summaryIsOneVietnameseLine() {
        let stats = StreamStats(updatesPerSecond: 18, megabitsPerSecond: 62.34, decodeMilliseconds: 4.1, drawMilliseconds: 3)
        #expect(stats.summary == "18 khung/s · 62,3 Mbit/s · giải mã 4,1 ms · vẽ 3,0 ms")
    }

    @Test func summaryShowsPacingWhenMeasured() {
        var stats = StreamStats(updatesPerSecond: 25, megabitsPerSecond: 20, decodeMilliseconds: 2.8, drawMilliseconds: 0.8)
        stats.pacing = FramePacing.Summary(medianInterval: 40.2, p95Interval: 66.7, updatesPerPresent: 1)
        #expect(stats.summary.hasSuffix("· nhịp 40/67 ms"))
    }
}
