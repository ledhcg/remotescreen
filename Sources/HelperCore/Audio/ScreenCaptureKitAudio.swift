#if os(macOS)
import AVFoundation
import CoreMedia
import Foundation
import os
@preconcurrency import ScreenCaptureKit

/// App-filtered audio through an audio-only-purpose `SCStream` (video is configured at 2x2 and ignored). Not run by
/// `swift test`; validated on a real Mac with the Screen Recording grant.
public final class ScreenCaptureKitAudioCapture: AudioCapturing, @unchecked Sendable {
    private struct Entry { let stream: SCStream; let sink: Sink }
    private let entries = OSAllocatedUnfairLock<[Int32: Entry]>(initialState: [:])

    public init() {}

    public func start(pid: Int32, channels: Int) async throws -> AsyncStream<PCMChunk> {
        await stop(pid: pid)
        let content: SCShareableContent
        do { content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false) } catch {
            throw AudioError.permissionDenied
        }
        guard let app = content.applications.first(where: { $0.processID == pid }), let display = content.displays.first else {
            throw AudioError.applicationNotFound
        }
        let filter = SCContentFilter(display: display, including: [app], exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = channels
        config.width = 2; config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        let (stream, continuation) = AsyncStream<PCMChunk>.makeStream(bufferingPolicy: .bufferingNewest(64))
        let sink = Sink(continuation: continuation, channels: channels)
        let scStream = SCStream(filter: filter, configuration: config, delegate: sink)
        do {
            try scStream.addStreamOutput(sink, type: .audio, sampleHandlerQueue: sink.queue)
            try await scStream.startCapture()
        } catch {
            continuation.finish()
            throw AudioError.failed((error as NSError).code)
        }
        entries.withLock { $0[pid] = Entry(stream: scStream, sink: sink) }
        return stream
    }

    public func stop(pid: Int32) async {
        guard let entry = entries.withLock({ $0.removeValue(forKey: pid) }) else { return }
        try? await entry.stream.stopCapture()
        entry.sink.finish()
    }

    private final class Sink: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
        let queue = DispatchQueue(label: "com.screon.helper.audio", qos: .userInteractive)
        private let continuation: AsyncStream<PCMChunk>.Continuation
        private let channels: Int
        init(continuation: AsyncStream<PCMChunk>.Continuation, channels: Int) { self.continuation = continuation; self.channels = channels }
        func finish() { continuation.finish() }
        func stream(_ stream: SCStream, didStopWithError error: Error) { continuation.finish() }

        func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
            guard type == .audio, CMSampleBufferIsValid(sampleBuffer), CMSampleBufferDataIsReady(sampleBuffer) else { return }
            var size = 0
            guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
                sampleBuffer, bufferListSizeNeededOut: &size, bufferListOut: nil, bufferListSize: 0, blockBufferAllocator: nil,
                blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: nil) == noErr || size > 0 else { return }
            let raw = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: MemoryLayout<AudioBufferList>.alignment)
            defer { raw.deallocate() }
            let list = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
            var block: CMBlockBuffer?
            guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
                sampleBuffer, bufferListSizeNeededOut: nil, bufferListOut: list, bufferListSize: size, blockBufferAllocator: nil,
                blockBufferMemoryAllocator: nil, flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment, blockBufferOut: &block) == noErr
            else { return }
            let buffers = UnsafeMutableAudioBufferListPointer(list)
            var planes: [[Float]] = []
            for b in buffers {
                guard let data = b.mData else { continue }
                let n = Int(b.mDataByteSize) / 4
                let floats = Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: n))
                if b.mNumberChannels > 1 {
                    continuation.yield(PCMChunk(ptsMicros: Self.micros(sampleBuffer), samples: PCMConversion.interleavedInt16(fromInterleaved: floats)))
                    return
                }
                planes.append(floats)
            }
            guard !planes.isEmpty else { return }
            continuation.yield(PCMChunk(ptsMicros: Self.micros(sampleBuffer), samples: PCMConversion.interleavedInt16(fromPlanar: planes)))
        }

        static func micros(_ sb: CMSampleBuffer) -> UInt64 {
            let pts = CMSampleBufferGetPresentationTimeStamp(sb)
            return pts.isNumeric ? UInt64(max(0, CMTimeConvertScale(pts, timescale: 1_000_000, method: .default).value)) : 0
        }
    }
}

/// Optional AAC-ELD mode: converts 48 kHz interleaved int16 PCM to AAC-ELD packets with `AVAudioConverter`.
/// Returns nil from `init` when the system has no such encoder.
public final class AACELDEncoder: @unchecked Sendable {
    private let converter: AVAudioConverter
    private let inputFormat: AVAudioFormat
    public let samplesPerPacket: AVAudioFrameCount = 512

    public init?(channels: Int, bitrate: Int = 64_000) {
        guard let input = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48_000, channels: AVAudioChannelCount(channels), interleaved: true) else { return nil }
        var desc = AudioStreamBasicDescription(
            mSampleRate: 48_000, mFormatID: kAudioFormatMPEG4AAC_ELD, mFormatFlags: 0, mBytesPerPacket: 0, mFramesPerPacket: 512,
            mBytesPerFrame: 0, mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 0, mReserved: 0)
        guard let output = AVAudioFormat(streamDescription: &desc), let converter = AVAudioConverter(from: input, to: output) else { return nil }
        converter.bitRate = bitrate
        self.converter = converter; self.inputFormat = input
    }

    /// Encodes exactly `samplesPerPacket` interleaved frames into one AAC-ELD packet, or nil on failure.
    public func encode(pcm: Data) -> Data? {
        let frames = AVAudioFrameCount(pcm.count / (Int(inputFormat.channelCount) * 2))
        guard frames == samplesPerPacket, let buffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames
        pcm.withUnsafeBytes { raw in
            if let dst = buffer.int16ChannelData?[0] { memcpy(dst, raw.baseAddress!, pcm.count) }
        }
        let output = AVAudioCompressedBuffer(format: converter.outputFormat, packetCapacity: 1, maximumPacketSize: converter.maximumOutputPacketSize)
        let supplied = OSAllocatedUnfairLock(initialState: false)
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if supplied.withLock({ let was = $0; $0 = true; return was }) { inputStatus.pointee = .noDataNow; return nil }
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, output.byteLength > 0 else { return nil }
        return Data(bytes: output.data, count: Int(output.byteLength))
    }
}
#endif
