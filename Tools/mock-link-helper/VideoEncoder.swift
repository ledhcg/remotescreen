import CoreMedia
import CoreVideo
import Foundation
import LinkProtocol
import VideoToolbox

struct EncodedFrame: Sendable {
    /// Length-prefixed NAL units exactly as VideoToolbox produced them.
    var data: Data
    var isKey: Bool
    var ptsMicros: UInt64
    /// Present on key frames (VPS/SPS/PPS for HEVC, SPS/PPS for H.264).
    var parameterSets: [Data]?
}

/// A real-time VideoToolbox session for the mock: HEVC first, H.264 when HEVC is unavailable (VMs, older Macs).
final class VideoEncoder: @unchecked Sendable {
    let codec: LinkVideoCodec
    private let session: VTCompressionSession
    private let onFrame: @Sendable (EncodedFrame) -> Void

    init(width: Int, height: Int, fps: Int, preferHEVC: Bool, onFrame: @escaping @Sendable (EncodedFrame) -> Void) throws {
        var candidates: [(CMVideoCodecType, LinkVideoCodec)] = []
        if preferHEVC { candidates.append((kCMVideoCodecType_HEVC, .hevc)) }
        candidates.append((kCMVideoCodecType_H264, .h264))
        var created: (VTCompressionSession, LinkVideoCodec)?
        for (type, link) in candidates {
            var session: VTCompressionSession?
            let status = VTCompressionSessionCreate(
                allocator: nil, width: Int32(width), height: Int32(height), codecType: type, encoderSpecification: nil,
                imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: nil, refcon: nil,
                compressionSessionOut: &session)
            if status == noErr, let session {
                created = (session, link)
                break
            }
        }
        guard let (session, link) = created else { throw MockError.message("no video encoder is available") }
        self.session = session
        codec = link
        self.onFrame = onFrame
        let bitrate = max(400_000, min(8_000_000, width * height * fps / 12))
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: fps as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: bitrate as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: 4 as CFNumber)
        guard VTCompressionSessionPrepareToEncodeFrames(session) == noErr else {
            VTCompressionSessionInvalidate(session)
            throw MockError.message("the video encoder did not start")
        }
    }

    func encode(_ pixelBuffer: CVPixelBuffer, ptsMicros: Int64, forceKey: Bool) {
        let properties: CFDictionary? = forceKey ? [kVTEncodeFrameOptionKey_ForceKeyFrame as String: true] as CFDictionary : nil
        let codec = self.codec
        let sink = onFrame
        VTCompressionSessionEncodeFrame(
            session, imageBuffer: pixelBuffer, presentationTimeStamp: CMTime(value: ptsMicros, timescale: 1_000_000),
            duration: .invalid, frameProperties: properties, infoFlagsOut: nil
        ) { status, _, sample in
            guard status == noErr, let sample, let frame = Self.convert(sample, codec: codec) else { return }
            sink(frame)
        }
    }

    func invalidate() {
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        VTCompressionSessionInvalidate(session)
    }

    private static func convert(_ sample: CMSampleBuffer, codec: LinkVideoCodec) -> EncodedFrame? {
        guard let block = CMSampleBufferGetDataBuffer(sample) else { return nil }
        let length = CMBlockBufferGetDataLength(block)
        guard length > 0 else { return nil }
        var data = Data(count: length)
        let copied = data.withUnsafeMutableBytes { raw in
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: raw.baseAddress!)
        }
        guard copied == kCMBlockBufferNoErr else { return nil }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
        let notSync = (attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool) ?? false
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        let micros = UInt64(max(0, CMTimeConvertScale(pts, timescale: 1_000_000, method: .default).value))
        var sets: [Data]?
        if !notSync, let description = CMSampleBufferGetFormatDescription(sample) {
            sets = parameterSets(description, codec: codec)
            if sets == nil { return nil }
        }
        return EncodedFrame(data: data, isKey: !notSync, ptsMicros: micros, parameterSets: sets)
    }

    private static func parameterSets(_ description: CMFormatDescription, codec: LinkVideoCodec) -> [Data]? {
        var count = 0
        var headerLength: Int32 = 0
        let first: OSStatus
        switch codec {
        case .hevc:
            first = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                description, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil,
                parameterSetCountOut: &count, nalUnitHeaderLengthOut: &headerLength)
        case .h264:
            first = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                description, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil,
                parameterSetCountOut: &count, nalUnitHeaderLengthOut: &headerLength)
        }
        guard first == noErr, headerLength == 4, count > 0 else { return nil }
        var sets: [Data] = []
        for index in 0..<count {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            let status: OSStatus
            switch codec {
            case .hevc:
                status = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                    description, parameterSetIndex: index, parameterSetPointerOut: &pointer, parameterSetSizeOut: &size,
                    parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
            case .h264:
                status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    description, parameterSetIndex: index, parameterSetPointerOut: &pointer, parameterSetSizeOut: &size,
                    parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
            }
            guard status == noErr, let pointer else { return nil }
            sets.append(Data(bytes: pointer, count: size))
        }
        return sets
    }
}
