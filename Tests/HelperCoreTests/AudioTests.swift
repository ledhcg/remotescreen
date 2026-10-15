#if os(macOS)
import Foundation
@testable import HelperCore
import LinkProtocol
import Testing

private func pcm(frames: Int, channels: Int = 2, value: Int16 = 1) -> Data {
    var d = Data(count: frames * channels * 2)
    d.withUnsafeMutableBytes { raw in raw.bindMemory(to: Int16.self).update(repeating: value) }
    return d
}

final class FakeAudioCapture: AudioCapturing, @unchecked Sendable {
    let continuation = Locked<AsyncStream<PCMChunk>.Continuation?>(nil)
    let stopped = Locked(0)
    func start(pid: Int32, channels: Int) async throws -> AsyncStream<PCMChunk> {
        let (s, c) = AsyncStream<PCMChunk>.makeStream()
        continuation.withValue { $0 = c }
        return s
    }
    func stop(pid: Int32) async { stopped.withValue { $0 += 1 }; continuation.get()?.finish() }
}

@Suite struct AudioTests {
    @Test func packetsAreFixedSizeSequencedAndTimestamped() throws {
        var p = try AudioPacketizer(pid: 42, frameMilliseconds: 10)
        #expect(p.frameSamples == 480 && p.frameBytes == 1920 && p.frameDurationMicros == 10_000)
        // 1000 frames arrive in odd-sized chunks.
        var packets: [LinkAudioPacket] = []
        var remaining = 1000, pts: UInt64 = 5_000_000
        for size in [333, 333, 334] {
            packets += p.append(PCMChunk(ptsMicros: pts, samples: pcm(frames: size)))
            pts += UInt64(size) * 1_000_000 / 48_000
            remaining -= size
        }
        #expect(remaining == 0 && packets.count == 2)  // 1000 / 480
        #expect(packets.map(\.sequence) == [0, 1])
        #expect(packets[0].ptsMicros == 5_000_000 && packets[1].ptsMicros == 5_010_000)
        #expect(packets.allSatisfy { $0.data.count == 1920 && $0.pid == 42 && $0.data.count <= LinkLimits.maxAudioPacketBytes })
        let more = p.append(PCMChunk(ptsMicros: pts, samples: pcm(frames: 480)))
        #expect(more.first?.sequence == 2)
    }

    @Test func configIsValidForTheWire() throws {
        let p = try AudioPacketizer(pid: 1, frameMilliseconds: 20)
        let cfg = p.makeConfig(codec: .opus)
        #expect(cfg.sampleRate == 48_000 && cfg.channels == 2 && cfg.frameDurationMicros == 20_000)
        #expect(Int(cfg.frameDurationMicros) * Int(cfg.sampleRate) / 1_000_000 * 4 <= LinkLimits.maxAudioPacketBytes)
    }

    @Test func invalidFormatsAreRejected() {
        #expect(throws: AudioError.invalidFormat) { _ = try AudioPacketizer(pid: 1, sampleRate: 1000) }
        #expect(throws: AudioError.invalidFormat) { _ = try AudioPacketizer(pid: 1, channels: 0) }
        #expect(throws: AudioError.invalidFormat) { _ = try AudioPacketizer(pid: 1, channels: 9) }
        #expect(throws: AudioError.invalidFormat) { _ = try AudioPacketizer(pid: 1, frameMilliseconds: 0) }
        // 100 ms of 8-channel 192 kHz would exceed the packet cap.
        #expect(throws: AudioError.invalidFormat) { _ = try AudioPacketizer(pid: 1, sampleRate: 192_000, channels: 8, frameMilliseconds: 100) }
    }

    @Test func backlogIsBounded() throws {
        var p = try AudioPacketizer(pid: 1, frameMilliseconds: 10)
        // A single 10 s chunk: only the newest second may survive, and every packet is still full size.
        let packets = p.append(PCMChunk(ptsMicros: 0, samples: pcm(frames: 480_000)))
        #expect(packets.count <= 101)
        #expect(packets.allSatisfy { $0.data.count == 1920 })
        #expect(p.droppedSamples > 0)
        #expect(packets.first!.ptsMicros >= 8_900_000)
    }

    @Test func raggedAndHostileInput() throws {
        var p = try AudioPacketizer(pid: 1)
        #expect(p.append(PCMChunk(ptsMicros: 0, samples: Data())).isEmpty)
        #expect(p.append(PCMChunk(ptsMicros: 0, samples: Data([1, 2, 3]))).isEmpty)  // less than one stereo sample frame
        #expect(p.append(PCMChunk(ptsMicros: 0, samples: pcm(frames: 10) + Data([9]))).isEmpty)
    }

    @Test func floatConversionClipsAndInterleaves() {
        let data = PCMConversion.interleavedInt16(fromPlanar: [[0, 1, -1, 2, .nan], [0.5, -0.5, 0, -2, 0]])
        let s = data.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
        #expect(s.count == 10)
        #expect(s[0] == 0 && s[1] == 16383)
        #expect(s[2] == 32767 && s[3] == -16383)
        #expect(s[4] == -32767 && s[5] == 0)
        #expect(s[6] == 32767 && s[7] == -32767)
        #expect(s[8] == 0)
        #expect(PCMConversion.interleavedInt16(fromPlanar: [[0, 1], [0]]).isEmpty)  // mismatched planes
    }

    @Test func fakeCaptureFeedsThePacketizer() async throws {
        let capture = FakeAudioCapture()
        let stream = try await capture.start(pid: 7, channels: 2)
        var p = try AudioPacketizer(pid: 7)
        capture.continuation.get()?.yield(PCMChunk(ptsMicros: 0, samples: pcm(frames: 960)))
        capture.continuation.get()?.finish()
        var out: [LinkAudioPacket] = []
        for await chunk in stream { out += p.append(chunk) }
        #expect(out.count == 2)
        await capture.stop(pid: 7)
        #expect(capture.stopped.get() == 1)
    }

    @Test func aacELDRoundTripsOnePacketWhenSupported() throws {
        guard let enc = AACELDEncoder(channels: 2) else { return }  // no encoder on this system: nothing to assert
        let out = enc.encode(pcm: pcm(frames: Int(enc.samplesPerPacket), value: 1000))
        if let out { #expect(!out.isEmpty && out.count <= LinkLimits.maxAudioPacketBytes) }
        #expect(enc.encode(pcm: pcm(frames: 10)) == nil)  // wrong frame count is refused
    }
}
#endif
