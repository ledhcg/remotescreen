#if os(macOS)
import Foundation
import LinkProtocol

/// How audio is carried on the link.
public enum AudioStreamMode: Sendable, Equatable {
    /// 48 kHz interleaved signed 16-bit PCM (LAN default).
    case pcm
    /// AAC-ELD, for when bandwidth is short.
    case aacELD
}

/// A chunk of captured audio: interleaved little-endian int16 samples.
public struct PCMChunk: Sendable, Equatable {
    public var ptsMicros: UInt64
    public var samples: Data
    public init(ptsMicros: UInt64, samples: Data) { self.ptsMicros = ptsMicros; self.samples = samples }
}

public enum AudioError: Error, Equatable {
    case invalidFormat
    case permissionDenied
    case applicationNotFound
    case failed(Int)
}

/// Per-application audio source. The real implementation uses ScreenCaptureKit; tests use a fake.
public protocol AudioCapturing: Sendable {
    /// Starts capturing the audio of `pid`. Chunks are 48 kHz interleaved int16 with `channels` channels.
    func start(pid: Int32, channels: Int) async throws -> AsyncStream<PCMChunk>
    func stop(pid: Int32) async
}

/// Cuts a PCM stream into fixed-duration `audio.packet`s with sequence numbers. Pure and bounded: the backlog never
/// exceeds `maxBacklogMilliseconds`, so a stalled consumer cannot grow memory (oldest samples are discarded).
public struct AudioPacketizer: Sendable {
    public let pid: Int32
    public let sampleRate: Int
    public let channels: Int
    public let frameSamples: Int
    public let maxBacklogMilliseconds = 1000

    private var buffer = Data()
    private var sequence: UInt32 = 0
    private var nextPTS: UInt64?
    public private(set) var droppedSamples = 0

    /// - Parameter frameMilliseconds: packet duration; 10 or 20 ms keeps latency low.
    public init(pid: Int32, sampleRate: Int = 48_000, channels: Int = 2, frameMilliseconds: Int = 10) throws {
        guard sampleRate >= Int(LinkLimits.minSampleRate), sampleRate <= Int(LinkLimits.maxSampleRate),
              channels >= 1, channels <= Int(LinkLimits.maxAudioChannels),
              frameMilliseconds >= 1, frameMilliseconds <= 100, sampleRate * frameMilliseconds % 1000 == 0
        else { throw AudioError.invalidFormat }
        let frame = sampleRate * frameMilliseconds / 1000
        guard frame * channels * 2 <= LinkLimits.maxAudioPacketBytes else { throw AudioError.invalidFormat }
        self.pid = pid; self.sampleRate = sampleRate; self.channels = channels; self.frameSamples = frame
    }

    public var frameBytes: Int { frameSamples * channels * 2 }
    public var frameDurationMicros: UInt32 { UInt32(frameSamples * 1_000_000 / sampleRate) }

    /// The `audio.config` for this stream. The wire enum only defines `.opus` today; the caller picks the value that
    /// the negotiated protocol assigns to `mode` (see the deviation noted in the H11 report).
    public func makeConfig(codec: LinkAudioCodec) -> LinkAudioConfig {
        LinkAudioConfig(pid: pid, codec: codec, sampleRate: UInt32(sampleRate), channels: UInt8(channels), frameDurationMicros: frameDurationMicros)
    }

    /// Adds samples and returns every complete packet. A trailing odd byte or partial frame stays buffered.
    public mutating func append(_ chunk: PCMChunk) -> [LinkAudioPacket] {
        if nextPTS == nil || buffer.isEmpty { nextPTS = chunk.ptsMicros }
        let usable = chunk.samples.count - chunk.samples.count % (channels * 2)
        guard usable > 0 else { return [] }
        buffer.append(chunk.samples.prefix(usable))

        let maxBytes = sampleRate * maxBacklogMilliseconds / 1000 * channels * 2
        if buffer.count > maxBytes {
            let excess = (buffer.count - maxBytes) / frameBytes * frameBytes + ((buffer.count - maxBytes) % frameBytes == 0 ? 0 : frameBytes)
            buffer.removeFirst(excess)
            droppedSamples += excess / (channels * 2)
            nextPTS = (nextPTS ?? 0) + UInt64(excess / (channels * 2) * 1_000_000 / sampleRate)
        }

        var packets: [LinkAudioPacket] = []
        while buffer.count >= frameBytes {
            let data = Data(buffer.prefix(frameBytes))
            buffer.removeFirst(frameBytes)
            let pts = nextPTS ?? 0
            packets.append(LinkAudioPacket(pid: pid, sequence: sequence, ptsMicros: pts, data: data))
            sequence &+= 1
            nextPTS = pts + UInt64(frameDurationMicros)
        }
        return packets
    }
}

/// Sample format conversion helpers (ScreenCaptureKit delivers 32-bit float, usually planar).
public enum PCMConversion {
    /// Planar float channels (equal length) to interleaved int16 with clipping.
    public static func interleavedInt16(fromPlanar planes: [[Float]]) -> Data {
        guard let count = planes.first?.count, planes.allSatisfy({ $0.count == count }) else { return Data() }
        var out = Data(count: count * planes.count * 2)
        out.withUnsafeMutableBytes { raw in
            let p = raw.bindMemory(to: Int16.self)
            for i in 0..<count {
                for (c, plane) in planes.enumerated() { p[i * planes.count + c] = Int16(littleEndian: convert(plane[i])) }
            }
        }
        return out
    }

    public static func interleavedInt16(fromInterleaved samples: [Float]) -> Data {
        var out = Data(count: samples.count * 2)
        out.withUnsafeMutableBytes { raw in
            let p = raw.bindMemory(to: Int16.self)
            for i in 0..<samples.count { p[i] = Int16(littleEndian: convert(samples[i])) }
        }
        return out
    }

    @inline(__always) private static func convert(_ v: Float) -> Int16 {
        guard v.isFinite else { return 0 }
        return Int16(max(-1, min(1, v)) * 32767)
    }
}
#endif
