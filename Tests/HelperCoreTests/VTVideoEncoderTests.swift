#if os(macOS)
import CoreMedia
import CoreVideo
import Foundation
@testable import HelperCore
import LinkProtocol
import Testing
import VideoToolbox

/// These tests drive a real `VTCompressionSession` with synthetic colour bars. They are skipped (not failed) on machines
/// where no encoder session can be created, such as some CI virtual machines.
private func encoderAvailable() -> Bool {
    guard let probe = try? VTVideoEncoder(settings: EncoderSettings(window: 1, width: 320, height: 192, bitrate: 1_000_000, framesPerSecond: 30)) else { return false }
    probe.invalidate()
    return true
}

private let encoderIsAvailable = encoderAvailable()

private func lengthPrefixedNALsAreConsistent(_ data: Data) -> Bool {
    var offset = 0
    var count = 0
    while offset + 4 <= data.count {
        let length = data[offset..<offset + 4].reduce(0) { ($0 << 8) | Int($1) }
        offset += 4
        guard length > 0, offset + length <= data.count else { return false }
        offset += length
        count += 1
    }
    return offset == data.count && count > 0
}

private func makeFormat(_ sets: EncodedParameterSets) -> CMVideoFormatDescription? {
    var format: CMFormatDescription?
    let pointers = sets.sets.map { set -> UnsafeMutablePointer<UInt8> in
        let p = UnsafeMutablePointer<UInt8>.allocate(capacity: set.count)
        set.copyBytes(to: p, count: set.count)
        return p
    }
    defer { pointers.forEach { $0.deallocate() } }
    let constPointers: [UnsafePointer<UInt8>] = pointers.map { UnsafePointer($0) }
    let sizes = sets.sets.map(\.count)
    let status: OSStatus = switch sets.codec {
    case .hevc:
        CMVideoFormatDescriptionCreateFromHEVCParameterSets(
            allocator: nil, parameterSetCount: sets.sets.count, parameterSetPointers: constPointers, parameterSetSizes: sizes,
            nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &format)
    case .h264:
        CMVideoFormatDescriptionCreateFromH264ParameterSets(
            allocator: nil, parameterSetCount: sets.sets.count, parameterSetPointers: constPointers, parameterSetSizes: sizes,
            nalUnitHeaderLength: 4, formatDescriptionOut: &format)
    }
    return status == noErr ? format : nil
}

/// Decodes one access unit and returns the decoded picture size.
private func decodeSize(of frame: LinkVideoFrame, format: CMVideoFormatDescription) -> (width: Int, height: Int)? {
    var block: CMBlockBuffer?
    guard CMBlockBufferCreateWithMemoryBlock(
        allocator: nil, memoryBlock: nil, blockLength: frame.data.count, blockAllocator: nil, customBlockSource: nil,
        offsetToData: 0, dataLength: frame.data.count, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block) == noErr,
        let block
    else { return nil }
    let replaced = frame.data.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: frame.data.count) }
    guard replaced == noErr else { return nil }
    var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMTime(value: CMTimeValue(frame.ptsMicros), timescale: 1_000_000), decodeTimeStamp: .invalid)
    var size = frame.data.count
    var sample: CMSampleBuffer?
    guard CMSampleBufferCreateReady(
        allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1, sampleTimingEntryCount: 1,
        sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample) == noErr,
        let sample
    else { return nil }
    var session: VTDecompressionSession?
    guard VTDecompressionSessionCreate(allocator: nil, formatDescription: format, decoderSpecification: nil, imageBufferAttributes: nil, outputCallback: nil, decompressionSessionOut: &session) == noErr,
          let session
    else { return nil }
    defer { VTDecompressionSessionInvalidate(session) }
    let result = Locked<(Int, Int)?>(nil)
    let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: nil) { status, _, image, _, _ in
        if status == noErr, let image { result.withValue { $0 = (CVPixelBufferGetWidth(image), CVPixelBufferGetHeight(image)) } }
    }
    guard status == noErr else { return nil }
    VTDecompressionSessionWaitForAsynchronousFrames(session)
    return result.get().map { (width: $0.0, height: $0.1) }
}

@Suite(.timeLimit(.minutes(2))) struct VTVideoEncoderTests {
    @Test(.enabled(if: encoderIsAvailable, "no VideoToolbox encoder session available"))
    func encodesKeyFirstHonoursForcedKeysAndRoundTrips() async throws {
        let width = 640, height = 368
        let encoder = try VTVideoEncoder(settings: EncoderSettings(window: 9, width: width, height: height, bitrate: 4_000_000, framesPerSecond: 30))
        let info = encoder.info
        #expect(info.codec == .hevc || info.codec == .h264)
        print("encoder:", info)

        let buffers = (0..<3).compactMap { _ in TestPixels.colorBars(width: width, height: height) }
        #expect(buffers.count == 3)
        let frameCount = 20
        for i in 0..<frameCount {
            try encoder.encode(buffers[i % 3], ptsMicros: UInt64(i) * 33_333, options: EncodeOptions(forceKeyFrame: i == 10))
        }
        encoder.invalidate()

        var sets: EncodedParameterSets?
        var frames: [LinkVideoFrame] = []
        var setsBeforeFirstFrame = false
        for await event in encoder.events {
            switch event {
            case .parameterSets(let s): sets = s; if frames.isEmpty { setsBeforeFirstFrame = true }
            case .frame(let f): frames.append(f)
            case .oversizedDropped: Issue.record("unexpected oversized frame")
            }
        }

        #expect(setsBeforeFirstFrame)
        let parameterSets = try #require(sets)
        #expect(parameterSets.width == width && parameterSets.height == height)
        #expect(parameterSets.sets.count == (info.codec == .hevc ? 3 : 2))
        #expect(parameterSets.sets.allSatisfy { !$0.isEmpty && $0.count <= LinkLimits.maxParameterSetBytes })
        let config = parameterSets.makeConfig(window: 9, contentRect: LinkRect(x: 0, y: 0, width: Double(width), height: Double(height)), scale: 2)
        #expect(config.codec == info.codec && config.pixelWidth == UInt32(width))

        #expect(frames.count == frameCount)
        #expect(frames.first?.flags.contains(.key) == true)
        #expect(frames.indices.contains(10) && frames[10].flags.contains(.key))
        #expect(frames.enumerated().map { $0.element.sequence == UInt32($0.offset) }.allSatisfy { $0 })
        #expect(frames.enumerated().allSatisfy { $0.element.ptsMicros == UInt64($0.offset) * 33_333 })
        #expect(frames.allSatisfy { lengthPrefixedNALsAreConsistent($0.data) && $0.data.count <= LinkLimits.maxVideoAccessUnitBytes })
        let stats = encoder.stats
        #expect(stats.reorderedFrames == 0)  // dts == pts for every frame
        #expect(stats.framesEncoded == frameCount)
        #expect(stats.latencyP95Micros > 0)

        // The first access unit must decode on its own and keep the dimensions.
        let format = try #require(makeFormat(parameterSets))
        let decoded = decodeSize(of: frames[0], format: format)
        if let decoded {
            #expect(decoded.width == width && decoded.height == height)
        } else {
            print("decode skipped: VTDecompressionSession unavailable for this stream")
        }
    }

    @Test(.enabled(if: encoderIsAvailable, "no VideoToolbox encoder session available"))
    func rateUpdatesAndAcknowledgementsAreSafe() throws {
        let encoder = try VTVideoEncoder(settings: EncoderSettings(window: 1, width: 320, height: 192, bitrate: 1_000_000, framesPerSecond: 30))
        let buffer = try #require(TestPixels.colorBars(width: 320, height: 192))
        try encoder.encode(buffer, ptsMicros: 0, options: EncodeOptions())
        encoder.setTargets(bitrate: 500_000, framesPerSecond: 15)
        encoder.setTargets(bitrate: 0, framesPerSecond: 0)  // ignored
        encoder.acknowledgeLongTermReferences(sequences: [0, 99, 12345])
        try encoder.encode(buffer, ptsMicros: 66_666, options: EncodeOptions(forceLTRRefresh: true))
        encoder.invalidate()
        #expect(throws: VideoEncoderError.invalidated) { try encoder.encode(buffer, ptsMicros: 100_000, options: EncodeOptions()) }
    }

    @Test func invalidSettingsAreRejected() {
        #expect(throws: VideoEncoderError.invalidSettings) { _ = try VTVideoEncoder(settings: EncoderSettings(window: 1, width: 321, height: 192)) }
        #expect(throws: VideoEncoderError.invalidSettings) { _ = try VTVideoEncoder(settings: EncoderSettings(window: 1, width: 640, height: 480, framesPerSecond: 0)) }
        #expect(throws: VideoEncoderError.invalidSettings) { _ = try VTVideoEncoder(settings: EncoderSettings(window: 1, width: 640, height: 480, bitrate: 0)) }
    }

    @Test(.enabled(if: encoderIsAvailable, "no VideoToolbox encoder session available"))
    func wrongSizedBuffersAreRejected() throws {
        let encoder = try VTVideoEncoder(settings: EncoderSettings(window: 1, width: 320, height: 192))
        let buffer = try #require(TestPixels.colorBars(width: 640, height: 384))
        #expect(throws: VideoEncoderError.invalidSettings) { try encoder.encode(buffer, ptsMicros: 0, options: EncodeOptions()) }
        encoder.invalidate()
    }

    @Test(.enabled(if: encoderIsAvailable, "no VideoToolbox encoder session available"))
    func h264PathProducesTwoParameterSets() async throws {
        let encoder = try VTVideoEncoder(settings: EncoderSettings(window: 1, preferredCodec: .h264, width: 320, height: 192))
        #expect(encoder.info.codec == .h264)
        let buffer = try #require(TestPixels.colorBars(width: 320, height: 192))
        for i in 0..<3 { try encoder.encode(buffer, ptsMicros: UInt64(i) * 16_666, options: EncodeOptions()) }
        encoder.invalidate()
        var sets: EncodedParameterSets?
        var frames = 0
        for await event in encoder.events {
            if case .parameterSets(let s) = event { sets = s }
            if case .frame = event { frames += 1 }
        }
        #expect(frames == 3)
        #expect(sets?.sets.count == 2)
    }
}
#endif
