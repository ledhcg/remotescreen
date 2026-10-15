import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox
@testable import RemoteDisplay

/// Builds a real HEVC / H.264 stream of synthetic colour bars with `VTCompressionSession`, in the length-prefixed form the helper sends.
/// Returns `nil` when the machine has no encoder for the codec (some CI VMs), so tests skip instead of failing.
enum VideoTestEncoder {
    struct Stream {
        var config: VideoStreamConfig
        var units: [VideoAccessUnit]
        var width: Int
        var height: Int
    }

    /// Video-range BT.709 values (Y, Cb, Cr) of the four bars: white, red, green, blue.
    static let bars: [(y: UInt8, cb: UInt8, cr: UInt8)] = [(235, 128, 128), (63, 102, 240), (173, 42, 26), (32, 240, 118)]

    static func makeBarsFrame(width: Int, height: Int, shift: Int = 0) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [String: Any](), kCVPixelBufferMetalCompatibilityKey: true]
        guard CVPixelBufferCreate(
            kCFAllocatorDefault, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, attributes as CFDictionary, &buffer
        ) == kCVReturnSuccess, let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let barWidth = width / bars.count
        let luma = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!.assumingMemoryBound(to: UInt8.self)
        let lumaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        for y in 0..<height {
            for x in 0..<width { luma[y * lumaStride + x] = bars[min(bars.count - 1, ((x + shift) % width) / barWidth)].y }
        }
        let chroma = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)!.assumingMemoryBound(to: UInt8.self)
        let chromaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
        for y in 0..<(height / 2) {
            for x in 0..<(width / 2) {
                let bar = bars[min(bars.count - 1, ((x * 2 + shift) % width) / barWidth)]
                chroma[y * chromaStride + x * 2] = bar.cb
                chroma[y * chromaStride + x * 2 + 1] = bar.cr
            }
        }
        return buffer
    }

    static func encode(codec: VideoCodec, width: Int, height: Int, frameCount: Int) -> Stream? {
        final class Collector: @unchecked Sendable {
            let lock = NSLock()
            var units: [VideoAccessUnit] = []
            var parameterSets: [Data] = []
            var nalLengthSize = 4
        }
        let collector = Collector()
        var created: VTCompressionSession?
        let type = codec == .hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264
        guard VTCompressionSessionCreate(
            allocator: nil, width: Int32(width), height: Int32(height), codecType: type, encoderSpecification: nil,
            imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: nil, refcon: nil, compressionSessionOut: &created
        ) == noErr, let session = created else { return nil }
        defer { VTCompressionSessionInvalidate(session) }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: 4_000_000 as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: 1000 as CFNumber)
        guard VTCompressionSessionPrepareToEncodeFrames(session) == noErr else { return nil }

        for index in 0..<frameCount {
            guard let frame = makeBarsFrame(width: width, height: height) else { return nil }
            let properties: CFDictionary? = index == 0 ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
            let pts = CMTime(value: CMTimeValue(index * 33_333), timescale: 1_000_000)
            let status = VTCompressionSessionEncodeFrame(
                session, imageBuffer: frame, presentationTimeStamp: pts, duration: .invalid, frameProperties: properties, infoFlagsOut: nil
            ) { status, _, sample in
                guard status == noErr, let sample, let block = CMSampleBufferGetDataBuffer(sample) else { return }
                let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
                let isKey = !(attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
                var length = 0
                var pointer: UnsafeMutablePointer<Int8>?
                guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer) == noErr,
                      let pointer else { return }
                let data = Data(bytes: pointer, count: length)
                collector.lock.lock()
                defer { collector.lock.unlock() }
                if isKey, collector.parameterSets.isEmpty, let format = CMSampleBufferGetFormatDescription(sample) {
                    var count = 0
                    var headerLength: Int32 = 0
                    func set(_ i: Int) -> Data? {
                        var p: UnsafePointer<UInt8>?
                        var size = 0
                        let s: OSStatus = codec == .hevc
                            ? CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, parameterSetIndex: i, parameterSetPointerOut: &p, parameterSetSizeOut: &size, parameterSetCountOut: &count, nalUnitHeaderLengthOut: &headerLength)
                            : CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: i, parameterSetPointerOut: &p, parameterSetSizeOut: &size, parameterSetCountOut: &count, nalUnitHeaderLengthOut: &headerLength)
                        guard s == noErr, let p else { return nil }
                        return Data(bytes: p, count: size)
                    }
                    if let first = set(0) {
                        collector.parameterSets = [first] + (1..<max(1, count)).compactMap(set)
                        collector.nalLengthSize = Int(headerLength)
                    }
                }
                collector.units.append(VideoAccessUnit(data: data, ptsMicros: UInt64(CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample)) * 1_000_000), isKey: isKey))
            }
            guard status == noErr else { return nil }
        }
        guard VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid) == noErr else { return nil }
        collector.lock.lock()
        defer { collector.lock.unlock() }
        guard collector.units.count == frameCount, collector.units.first?.isKey == true, !collector.parameterSets.isEmpty else { return nil }
        return Stream(
            config: VideoStreamConfig(codec: codec, parameterSets: collector.parameterSets, nalLengthSize: collector.nalLengthSize),
            units: collector.units, width: width, height: height
        )
    }

    /// `true` when this machine can encode and decode `codec` (probe once per codec).
    static func isAvailable(_ codec: VideoCodec) -> Bool {
        guard let stream = encode(codec: codec, width: 128, height: 64, frameCount: 1) else { return false }
        let decoder = VideoStreamDecoder()
        guard (try? decoder.configure(stream.config)) != nil else { return false }
        return decoder.decode(stream.units[0]) == .decoded
    }
}

/// Reads one pixel's (Y, Cb, Cr) from a 420v buffer.
func ycbcr(_ buffer: CVPixelBuffer, x: Int, y: Int) -> (y: Int, cb: Int, cr: Int) {
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    let luma = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!.assumingMemoryBound(to: UInt8.self)
    let chroma = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)!.assumingMemoryBound(to: UInt8.self)
    let lumaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0), chromaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
    return (Int(luma[y * lumaStride + x]), Int(chroma[(y / 2) * chromaStride + (x / 2) * 2]), Int(chroma[(y / 2) * chromaStride + (x / 2) * 2 + 1]))
}
