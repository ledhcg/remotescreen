import Foundation
import LinkProtocol
import Testing
@testable import WindowKit

@Suite struct AudioPlayoutTests {
    static let rate = 48_000

    /// `frames` stereo frames of constant value `value`, as little-endian 16-bit PCM.
    static func pcm(_ frames: Int, value: Int16 = 1000, channels: Int = 2) -> Data {
        var data = Data(capacity: frames * channels * 2)
        for _ in 0..<(frames * channels) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        return data
    }

    static func ramp(_ frames: Int, from start: Int) -> Data {
        var data = Data()
        for f in 0..<frames {
            let v = Int16(start + f)
            for _ in 0..<2 { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        }
        return data
    }

    static func render(_ playout: AudioPlayout, frames: Int) -> [Int16] {
        var out = [Int16](repeating: 77, count: frames * playout.channels)
        out.withUnsafeMutableBufferPointer { playout.render(into: $0.baseAddress!, frames: frames) }
        return out
    }

    // MARK: Jitter estimator

    @Test func steadyArrivalKeepsTheMinimumTarget() {
        var jitter = JitterEstimator()
        for i in 0..<200 { jitter.record(arrival: Double(i) * 0.01, ptsMicros: UInt64(i) * 10_000) }
        #expect(jitter.jitterSeconds < 0.0001)
        #expect(abs(jitter.targetMillis - 20) < 0.001)
    }

    @Test func jitterRaisesTheTargetButNeverPastForty() {
        var jitter = JitterEstimator()
        for i in 0..<400 {
            let wobble = i % 2 == 0 ? 0.0 : 0.012  // 12 ms late every other packet
            jitter.record(arrival: Double(i) * 0.01 + wobble, ptsMicros: UInt64(i) * 10_000)
        }
        #expect(jitter.targetMillis > 20)
        #expect(jitter.targetMillis <= 40)
        var wild = JitterEstimator()
        for i in 0..<400 { wild.record(arrival: Double(i) * 0.01 + (i % 2 == 0 ? 0 : 0.3), ptsMicros: UInt64(i) * 10_000) }
        #expect(wild.targetMillis == 40)
    }

    @Test func aPauseOrBackwardsClockResetsInsteadOfPoisoningTheEstimate() {
        var jitter = JitterEstimator()
        for i in 0..<50 { jitter.record(arrival: Double(i) * 0.01, ptsMicros: UInt64(i) * 10_000) }
        jitter.record(arrival: 60, ptsMicros: 50 * 10_000)  // a minute-long gap
        #expect(jitter.jitterSeconds == 0)
        jitter.record(arrival: 59, ptsMicros: 51 * 10_000)  // arrival clock went back
        #expect(jitter.jitterSeconds == 0)
        jitter.record(arrival: .nan, ptsMicros: 52 * 10_000)
        #expect(jitter.jitterSeconds == 0)
    }

    // MARK: Drift policy

    @Test func driftIsIdleInsideTheDeadBand() {
        var policy = DriftPolicy(sampleRate: Self.rate)
        for _ in 0..<100 { #expect(policy.correction(bufferedFrames: 960 + 100, targetFrames: 960, renderFrames: 512) == 0) }
    }

    @Test func driftIsRateLimited() {
        var policy = DriftPolicy(sampleRate: Self.rate)
        var total = 0
        for _ in 0..<100 { total += policy.correction(bufferedFrames: 5000, targetFrames: 960, renderFrames: 480) }
        // One frame per 480 rendered frames at most.
        #expect(total == 100)
        var inserting = DriftPolicy(sampleRate: Self.rate)
        var inserted = 0
        for _ in 0..<100 { inserted += inserting.correction(bufferedFrames: 0, targetFrames: 960, renderFrames: 480) }
        #expect(inserted == -100)
    }

    @Test func smallRendersAccumulateTheirBudget() {
        var policy = DriftPolicy(sampleRate: Self.rate)
        var total = 0
        for _ in 0..<40 { total += policy.correction(bufferedFrames: 5000, targetFrames: 960, renderFrames: 128) }
        #expect(total == 10)  // 5120 frames rendered, one per 480
    }

    // MARK: Ring

    @Test func ringWrapsAndDropsTheOldestOnOverflow() {
        var ring = AudioRing(channels: 2, capacityFrames: 4)
        defer { ring.deallocate() }
        Self.ramp(3, from: 1).withUnsafeBytes { #expect(ring.write(littleEndian: $0) == 0) }
        var out = [Int16](repeating: 0, count: 8)
        #expect(ring.read(into: &out, frames: 2) == 2)
        #expect(out[0] == 1 && out[2] == 2)
        Self.ramp(4, from: 10).withUnsafeBytes { #expect(ring.write(littleEndian: $0) == 1) }  // 1 left + 4 new > 4
        #expect(ring.availableFrames == 4)
        #expect(ring.read(into: &out, frames: 8) == 4)
        #expect(out[0] == 10 && out[6] == 13)
    }

    @Test func oversizedWriteKeepsTheNewestFrames() {
        var ring = AudioRing(channels: 2, capacityFrames: 4)
        defer { ring.deallocate() }
        Self.ramp(10, from: 100).withUnsafeBytes { #expect(ring.write(littleEndian: $0) == 6) }
        var out = [Int16](repeating: 0, count: 8)
        #expect(ring.read(into: &out, frames: 4) == 4)
        #expect(out[0] == 106 && out[6] == 109)
    }

    @Test func partialFramesAtTheEndOfAPacketAreIgnored() {
        var ring = AudioRing(channels: 2, capacityFrames: 8)
        defer { ring.deallocate() }
        var bytes = Self.ramp(2, from: 1)
        bytes.append(contentsOf: [1, 2, 3])
        bytes.withUnsafeBytes { _ = ring.write(littleEndian: $0) }
        #expect(ring.availableFrames == 2)
    }

    // MARK: Playout

    @Test func silenceUntilTheTargetIsBuffered() {
        let playout = AudioPlayout(sampleRate: Self.rate, channels: 2)
        playout.push(Self.pcm(480), ptsMicros: 0, arrival: 0)  // 10 ms, target is 20
        #expect(Self.render(playout, frames: 256).allSatisfy { $0 == 0 })
        playout.push(Self.pcm(960), ptsMicros: 10_000, arrival: 0.01)
        let started = Self.render(playout, frames: 256)
        #expect(started.contains { $0 != 0 })
        #expect(playout.stats.underruns == 0)
    }

    @Test func playsAudioInOrderAndStartsWithAFadeIn() {
        let playout = AudioPlayout(sampleRate: Self.rate, channels: 2)
        playout.push(Self.ramp(2000, from: 1), ptsMicros: 0, arrival: 0)
        let out = Self.render(playout, frames: 400)
        // Fade in over the first 96 frames (2 ms), then the ramp unchanged.
        #expect(abs(Int(out[0])) < 5)
        #expect(out[2 * 200] == 201 && out[2 * 399] == 400)
        #expect(zip(out.indices.dropFirst(2), out.dropFirst(2)).allSatisfy { $0.1 >= out[$0.0 - 2] })
    }

    @Test func underrunFadesToSilenceCountsAndWaitsToRefill() {
        let playout = AudioPlayout(sampleRate: Self.rate, channels: 2)
        playout.push(Self.pcm(1000, value: 10_000), ptsMicros: 0, arrival: 0)
        _ = Self.render(playout, frames: 500)
        let out = Self.render(playout, frames: 700)  // only ~500 frames left
        #expect(playout.stats.underruns == 1)
        #expect(out[2 * 600] == 0 && out[2 * 699] == 0)
        // The fade ends at zero; it does not stop at a step.
        let lastLoud: Int = (0..<700).reversed().first { out[$0 * 2] != 0 } ?? 0
        #expect(out[lastLoud * 2] < 1000)
        // Not enough buffered again: stays silent. Enough: plays.
        playout.push(Self.pcm(300), ptsMicros: 30_000, arrival: 0.03)
        #expect(Self.render(playout, frames: 100).allSatisfy { $0 == 0 })
        playout.push(Self.pcm(1200), ptsMicros: 40_000, arrival: 0.04)
        #expect(Self.render(playout, frames: 100).contains { $0 != 0 })
        #expect(playout.stats.glitches == 1)
    }

    @Test func mutingDropsBufferedAudioAndIgnoresPackets() {
        let playout = AudioPlayout(sampleRate: Self.rate, channels: 2)
        playout.push(Self.pcm(2000), ptsMicros: 0, arrival: 0)
        playout.setMuted(true)
        #expect(playout.stats.bufferedMillis == 0)
        playout.push(Self.pcm(2000), ptsMicros: 40_000, arrival: 0.04)
        #expect(playout.stats.bufferedMillis == 0)
        #expect(Self.render(playout, frames: 256).allSatisfy { $0 == 0 })
        playout.setMuted(false)
        playout.push(Self.pcm(2000), ptsMicros: 80_000, arrival: 0.08)
        #expect(Self.render(playout, frames: 256).contains { $0 != 0 })
    }

    @Test func aBufferFarAboveTargetIsTrimmedAtOnce() {
        let playout = AudioPlayout(sampleRate: Self.rate, channels: 2)
        playout.push(Self.pcm(9600), ptsMicros: 0, arrival: 0)  // 200 ms
        _ = Self.render(playout, frames: 256)
        let stats = playout.stats
        #expect(stats.overflows == 1)
        #expect(stats.bufferedMillis <= 25)
    }

    @Test func aBufferAboveTargetDrainsByDroppingSingleFrames() {
        let playout = AudioPlayout(sampleRate: Self.rate, channels: 2)
        playout.push(Self.pcm(2400), ptsMicros: 0, arrival: 0)  // 50 ms; target 20 ms, dead band 4 ms
        _ = Self.render(playout, frames: 256)
        for _ in 0..<3 { _ = Self.render(playout, frames: 480) }
        #expect(playout.stats.droppedFrames > 0)
        #expect(playout.stats.droppedFrames <= 4)
        #expect(playout.stats.insertedFrames == 0)
        #expect(playout.stats.underruns == 0)
    }

    @Test func aFastSenderClockMakesTheBufferGrowSoFramesAreRepeatedNotDropped() {
        let playout = AudioPlayout(sampleRate: Self.rate, channels: 2)
        playout.push(Self.pcm(960), ptsMicros: 0, arrival: 0)  // exactly the target
        _ = Self.render(playout, frames: 256)  // 704 left: 256 frames (5 ms) under the target
        _ = Self.render(playout, frames: 256)
        let stats = playout.stats
        #expect(stats.insertedFrames == 1)
        #expect(stats.droppedFrames == 0)
        #expect(stats.underruns == 0)
    }

    @Test func everyRenderWritesEverySample() {
        let playout = AudioPlayout(sampleRate: Self.rate, channels: 2)
        playout.push(Self.pcm(1200, value: 5), ptsMicros: 0, arrival: 0)
        for frames in [1, 7, 64, 480, 1024, 4096] {
            let out = Self.render(playout, frames: frames)
            #expect(!out.contains(77), "render of \(frames) frames left stale samples")
        }
    }

    @Test func monoStreamsWork() {
        let playout = AudioPlayout(sampleRate: 24_000, channels: 1)
        var data = Data()
        for i in 0..<1000 { withUnsafeBytes(of: Int16(i).littleEndian) { data.append(contentsOf: $0) } }
        playout.push(data, ptsMicros: 0, arrival: 0)
        let out = Self.render(playout, frames: 300)
        #expect(zip(out.dropFirst(), out).allSatisfy { $0.0 >= $0.1 })  // still in order, single samples may be skipped
        #expect(out[299] >= 299)
    }
}

@Suite struct AudioMutePolicyTests {
    func workspace() -> RemoteWorkspace {
        var workspace = RemoteWorkspace()
        _ = workspace.apply(.snapshot(LinkSnapshot(stateVersion: 1, apps: [], windows: [
            LinkWindowInfo(id: 1, pid: 10, bundleID: "a", frame: LinkRect(x: 0, y: 0, width: 100, height: 100), scale: 2, title: "A1"),
            LinkWindowInfo(id: 2, pid: 10, bundleID: "a", frame: LinkRect(x: 0, y: 0, width: 100, height: 100), scale: 2, title: "A2"),
            LinkWindowInfo(id: 3, pid: 11, bundleID: "b", frame: LinkRect(x: 0, y: 0, width: 100, height: 100), scale: 2, title: "B"),
        ])))
        return workspace
    }

    func subscribe(_ manager: inout SubscriptionManager, _ id: UInt32) {
        _ = manager.connectionEstablished()
        _ = manager.subscribe(LinkSubscribe(window: WindowID(rawValue: id), pixelWidth: 100, pixelHeight: 100, maxFramesPerSecond: 60, quality: .balanced))
    }

    @Test func anAppWithNoWantedWindowIsMuted() {
        var manager = SubscriptionManager()
        subscribe(&manager, 3)
        #expect(AudioMutePolicy.mutedPIDs(pids: [10, 11], workspace: workspace(), subscriptions: manager) == [10])
    }

    @Test func backgroundingTheOnlySceneMutesItsApp() {
        var manager = SubscriptionManager()
        subscribe(&manager, 1)
        subscribe(&manager, 3)
        _ = manager.pause(3)
        #expect(AudioMutePolicy.mutedPIDs(pids: [10, 11], workspace: workspace(), subscriptions: manager) == [11])
    }

    @Test func anAppStaysAudibleWhileAnyOfItsWindowsIsOnScreen() {
        var manager = SubscriptionManager()
        subscribe(&manager, 1)
        subscribe(&manager, 2)
        _ = manager.pause(1)
        #expect(AudioMutePolicy.mutedPIDs(pids: [10], workspace: workspace(), subscriptions: manager).isEmpty)
        _ = manager.pause(2)
        #expect(AudioMutePolicy.mutedPIDs(pids: [10], workspace: workspace(), subscriptions: manager) == [10])
    }
}
