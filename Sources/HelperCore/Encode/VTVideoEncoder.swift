#if os(macOS)
import CoreMedia
import CoreVideo
import Foundation
import LinkProtocol
import os
import VideoToolbox

/// HEVC (H.264 fallback) encoder on a `VTCompressionSession`, tuned for latency: real-time, no frame reordering,
/// `MaxFrameDelayCount` 0, low-latency rate control when the hardware accepts it.
///
/// Thread model: `encode` may be called from any one thread at a time; VideoToolbox calls back on its own queue. All
/// shared state sits behind one unfair lock that is never held across a VideoToolbox call.
public final class VTVideoEncoder: VideoEncoding, @unchecked Sendable {
    /// `VTCompressionSession` is not marked `Sendable`, but VideoToolbox documents its session calls as thread-safe
    /// (encode, property access and invalidate may race with its own callback queue).
    private struct SessionRef: @unchecked Sendable {
        let session: VTCompressionSession
        init(_ session: VTCompressionSession) { self.session = session }
    }

    private struct Pending { let ptsMicros: UInt64; let refresh: Bool; let submittedNanos: UInt64 }

    private struct State {
        var session: SessionRef?
        var pending: [Pending] = []
        var sequence: UInt32 = 0
        var lastParameterSets: [Data] = []
        var bitrate: Int
        var fps: Int
        var forceKeyNext = false
        var stats = EncoderStats()
        var latencies = [UInt64](repeating: 0, count: 256)
        var latencyCount = 0
        /// LTR frame sequence -> VideoToolbox token, oldest first, bounded.
        var ltrTokens: [(sequence: UInt32, token: Int)] = []
        var acknowledged: [Int] = []
    }

    public let info: EncoderInfo
    public let events: AsyncStream<EncoderEvent>
    private let continuation: AsyncStream<EncoderEvent>.Continuation
    private let settings: EncoderSettings
    private let box: OwnerBox
    private let state: OSAllocatedUnfairLock<State>
    private let log = Logger(subsystem: "com.screon.helper", category: "encode")

    public var stats: EncoderStats {
        state.withLock { s in
            var out = s.stats
            let n = min(s.latencyCount, s.latencies.count)
            if n > 0 {
                let sorted = s.latencies[0..<n].sorted()
                out.latencyP95Micros = sorted[min(n - 1, Int(Double(n) * 0.95))]
            }
            return out
        }
    }

    // MARK: Creation

    /// Creates the session. Throws `sessionUnavailable` when no codec/mode combination can be created (for example in a VM).
    public init(settings: EncoderSettings) throws {
        guard settings.width >= 16, settings.height >= 16, settings.width % 2 == 0, settings.height % 2 == 0,
              settings.width <= Int(LinkLimits.maxPixelDimension), settings.height <= Int(LinkLimits.maxPixelDimension),
              settings.framesPerSecond > 0, Int(LinkLimits.maxFramesPerSecond) >= settings.framesPerSecond, settings.bitrate > 0
        else { throw VideoEncoderError.invalidSettings }
        self.settings = settings
        (events, continuation) = AsyncStream<EncoderEvent>.makeStream(bufferingPolicy: .unbounded)
        state = OSAllocatedUnfairLock(initialState: State(bitrate: settings.bitrate, fps: settings.framesPerSecond))

        let box = OwnerBox()
        let codecs: [LinkVideoCodec] = settings.preferredCodec == .hevc ? [.hevc, .h264] : [.h264]
        var created: (SessionRef, EncoderInfo)?
        search: for codec in codecs {
            for lowLatency in [true, false] {
                if let result = Self.makeSession(settings: settings, codec: codec, lowLatency: lowLatency, box: box) {
                    // HEVC must be hardware accelerated to be worth it; software HEVC is slower than hardware H.264.
                    if codec == .hevc, !result.1.hardwareAccelerated, codecs.count > 1 {
                        VTCompressionSessionInvalidate(result.0.session)
                        continue search
                    }
                    created = result
                    break search
                }
            }
        }
        guard let (session, info) = created else { throw VideoEncoderError.sessionUnavailable }
        self.info = info
        state.withLock { $0.session = session }
        self.box = box
        box.owner.withLock { $0 = Unmanaged.passUnretained(self) }
    }

    deinit { invalidate() }

    // MARK: Session construction

    /// What the C callback's refcon points at. A refcon cannot change after session creation, but the encoder does not
    /// exist yet while the session is being created, so the callback goes through this box, which `init` points at the
    /// encoder once it is fully built and `invalidate` clears again.
    private final class OwnerBox: @unchecked Sendable {
        let owner = OSAllocatedUnfairLock<Unmanaged<VTVideoEncoder>?>(initialState: nil)
    }

    private static let outputCallback: VTCompressionOutputCallback = { refcon, _, status, flags, sampleBuffer in
        guard let refcon else { return }
        let box = Unmanaged<OwnerBox>.fromOpaque(refcon).takeUnretainedValue()  // kept alive by the encoder, which outlives the session
        // Hold the lock for the whole callback so `invalidate` (which unbinds) cannot free the encoder underneath it.
        box.owner.withLockUnchecked { owner in
            owner?.takeUnretainedValue().handleOutput(status: status, flags: flags, sampleBuffer: sampleBuffer)
        }
    }

    private static func makeSession(
        settings: EncoderSettings, codec: LinkVideoCodec, lowLatency: Bool, box: OwnerBox
    ) -> (SessionRef, EncoderInfo)? {
        var spec: [CFString: Any] = [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true]
        if lowLatency { spec[kVTVideoEncoderSpecification_EnableLowLatencyRateControl] = true }
        let imageAttrs: [CFString: Any] = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
        let refcon = Unmanaged.passUnretained(box).toOpaque()
        var out: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: nil, width: Int32(settings.width), height: Int32(settings.height),
            codecType: codec == .hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264,
            encoderSpecification: spec as CFDictionary, imageBufferAttributes: imageAttrs as CFDictionary,
            compressedDataAllocator: nil, outputCallback: outputCallback, refcon: refcon, compressionSessionOut: &out)
        guard status == noErr, let session = out else { return nil }

        func set(_ key: CFString, _ value: CFTypeRef) -> Bool { VTSessionSetProperty(session, key: key, value: value) == noErr }

        var usedPreset = false
        if lowLatency, #available(macOS 26.0, *) { usedPreset = applyVideoConferencingPreset(session) }
        _ = set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
        _ = set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
        _ = set(kVTCompressionPropertyKey_MaxFrameDelayCount, 0 as CFNumber)
        _ = set(kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, kCFBooleanTrue)
        _ = set(kVTCompressionPropertyKey_ProfileLevel, codec == .hevc ? kVTProfileLevel_HEVC_Main_AutoLevel : kVTProfileLevel_H264_High_AutoLevel)
        _ = set(kVTCompressionPropertyKey_ColorPrimaries, kCMFormatDescriptionColorPrimaries_ITU_R_709_2)
        _ = set(kVTCompressionPropertyKey_TransferFunction, kCMFormatDescriptionTransferFunction_ITU_R_709_2)
        _ = set(kVTCompressionPropertyKey_YCbCrMatrix, kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2)
        _ = set(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, settings.maxKeyFrameIntervalSeconds as CFNumber)
        applyRate(session, bitrate: settings.bitrate, fps: settings.framesPerSecond)
        var ltr = false
        if settings.enableLongTermReferences { ltr = set(kVTCompressionPropertyKey_EnableLTR, kCFBooleanTrue) }

        guard VTCompressionSessionPrepareToEncodeFrames(session) == noErr else {
            VTCompressionSessionInvalidate(session)
            return nil
        }
        var hw: CFTypeRef?
        let hwStatus = withUnsafeMutablePointer(to: &hw) {
            VTSessionCopyProperty(session, key: kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder, allocator: nil, valueOut: $0)
        }
        // The low-latency rate control encoder does not expose this property (kVTPropertyNotSupportedErr, observed on
        // macOS 27) but exists only as a hardware encoder, so a successful low-latency session counts as hardware.
        let hardware = hwStatus == noErr ? ((hw as? NSNumber)?.boolValue ?? false) : lowLatency
        return (SessionRef(session), EncoderInfo(
            codec: codec, rateControl: lowLatency ? .lowLatency : .standard, hardwareAccelerated: hardware,
            usedVideoConferencingPreset: usedPreset, longTermReferences: ltr))
    }

    /// Applies Apple's VideoConferencing preset (macOS 26+) when the encoder lists it. Our own properties are set after it.
    @available(macOS 26.0, *)
    private static func applyVideoConferencingPreset(_ session: VTCompressionSession) -> Bool {
        var value: CFTypeRef?
        let status = withUnsafeMutablePointer(to: &value) {
            VTSessionCopyProperty(session, key: kVTCompressionPropertyKey_SupportedPresetDictionaries, allocator: nil, valueOut: $0)
        }
        guard status == noErr, let presets = value as? [String: Any],
              let preset = presets[kVTCompressionPreset_VideoConferencing as String] as? [String: Any]
        else { return false }
        return VTSessionSetProperties(session, propertyDictionary: preset as CFDictionary) == noErr
    }

    private static func applyRate(_ session: VTCompressionSession, bitrate: Int, fps: Int) {
        _ = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: bitrate as CFNumber)
        _ = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: fps as CFNumber)
        // Hard ceiling: 1.5x the average over one second, so a text-heavy key frame cannot flood the link.
        let limits = [Double(bitrate) / 8 * 1.5, 1.0] as CFArray
        _ = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits, value: limits)
    }

    // MARK: Encoding

    public func encode(_ pixelBuffer: CVPixelBuffer, ptsMicros: UInt64, options: EncodeOptions) throws {
        guard CVPixelBufferGetWidth(pixelBuffer) == settings.width, CVPixelBufferGetHeight(pixelBuffer) == settings.height else {
            throw VideoEncoderError.invalidSettings
        }
        let prepared = state.withLock { s -> (SessionRef, Bool, [Int], Int)? in
            guard let session = s.session else { return nil }
            let forceKey = options.forceKeyFrame || s.forceKeyNext
            s.forceKeyNext = false
            let acks = s.acknowledged
            s.acknowledged.removeAll(keepingCapacity: true)
            s.pending.append(Pending(ptsMicros: ptsMicros, refresh: options.forceLTRRefresh, submittedNanos: clock_gettime_nsec_np(CLOCK_UPTIME_RAW)))
            return (session, forceKey, acks, s.fps)
        }
        guard let (session, forceKey, acks, fps) = prepared else { throw VideoEncoderError.invalidated }

        // Frame options are built only when something is requested, so ordinary frames allocate nothing here.
        var properties: CFDictionary?
        if forceKey || options.forceLTRRefresh || !acks.isEmpty {
            var dict: [CFString: Any] = [:]
            if forceKey { dict[kVTEncodeFrameOptionKey_ForceKeyFrame] = true }
            if options.forceLTRRefresh { dict[kVTEncodeFrameOptionKey_ForceLTRRefresh] = true }
            if !acks.isEmpty { dict[kVTEncodeFrameOptionKey_AcknowledgedLTRTokens] = acks }
            properties = dict as CFDictionary
        }
        let status = VTCompressionSessionEncodeFrame(
            session.session, imageBuffer: pixelBuffer, presentationTimeStamp: CMTime(value: CMTimeValue(ptsMicros), timescale: 1_000_000),
            duration: CMTime(value: 1, timescale: CMTimeScale(fps)), frameProperties: properties, sourceFrameRefcon: nil, infoFlagsOut: nil)
        if status != noErr {
            state.withLock { s in
                if let i = s.pending.lastIndex(where: { $0.ptsMicros == ptsMicros }) { s.pending.remove(at: i) }
                s.stats.framesDropped += 1
                if forceKey { s.forceKeyNext = true }
            }
            throw VideoEncoderError.encodeFailed(status)
        }
    }

    public func setTargets(bitrate: Int, framesPerSecond: Int) {
        guard bitrate > 0, framesPerSecond > 0 else { return }
        let session = state.withLock { s -> SessionRef? in
            s.bitrate = bitrate; s.fps = min(framesPerSecond, Int(LinkLimits.maxFramesPerSecond))
            return s.session
        }
        if let session { Self.applyRate(session.session, bitrate: bitrate, fps: framesPerSecond) }
    }

    public func acknowledgeLongTermReferences(sequences: [UInt32]) {
        state.withLock { s in
            for seq in sequences.prefix(LinkLimits.maxLTRTokens) {
                guard let i = s.ltrTokens.firstIndex(where: { $0.sequence == seq }) else { continue }
                s.acknowledged.append(s.ltrTokens[i].token)
                s.ltrTokens.remove(at: i)
            }
            if s.acknowledged.count > LinkLimits.maxLTRTokens { s.acknowledged.removeFirst(s.acknowledged.count - LinkLimits.maxLTRTokens) }
        }
    }

    public func invalidate() {
        let ref = state.withLock { s -> SessionRef? in
            defer { s.session = nil }
            return s.session
        }
        if let session = ref?.session {
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(session)
        }
        box.owner.withLock { $0 = nil }
        continuation.finish()
    }

    // MARK: Output

    private func handleOutput(status: OSStatus, flags: VTEncodeInfoFlags, sampleBuffer: CMSampleBuffer?) {
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let pending = state.withLock { s in s.pending.isEmpty ? nil : s.pending.removeFirst() }
        guard status == noErr, !flags.contains(.frameDropped), let sampleBuffer, CMSampleBufferDataIsReady(sampleBuffer),
              let pending, let format = CMSampleBufferGetFormatDescription(sampleBuffer),
              let block = CMSampleBufferGetDataBuffer(sampleBuffer)
        else {
            state.withLock { $0.stats.framesDropped += 1 }
            return
        }

        let attachments = (CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]])?.first
        let isKey = !((attachments?[kCMSampleAttachmentKey_NotSync] as? Bool) ?? false)
        let ltrToken = (attachments?[kVTSampleAttachmentKey_RequireLTRAcknowledgementToken] as? NSNumber)?.intValue
        let dts = CMSampleBufferGetDecodeTimeStamp(sampleBuffer), pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let reordered = dts.isValid && pts.isValid && dts != pts

        let length = CMBlockBufferGetDataLength(block)
        guard length > 0 else { return }
        if length > LinkLimits.maxVideoAccessUnitBytes {
            // Never send a frame the peer must reject. Halve the rate and restart from a key frame.
            let session = state.withLock { s -> SessionRef? in
                s.stats.oversizedFrames += 1
                s.bitrate = max(250_000, s.bitrate / 2)
                s.forceKeyNext = true
                return s.session
            }
            if let session { let (b, f) = state.withLock { ($0.bitrate, $0.fps) }; Self.applyRate(session.session, bitrate: b, fps: f) }
            log.error("access unit of \(length) bytes exceeds the cap; lowering bitrate")
            continuation.yield(.oversizedDropped(bytes: length))
            return
        }

        var parameterSets: EncodedParameterSets?
        if let sets = Self.parameterSets(from: format, codec: info.codec) {
            let changed = state.withLock { s -> Bool in
                if s.lastParameterSets == sets.sets { return false }
                s.lastParameterSets = sets.sets
                return true
            }
            if changed { parameterSets = sets }
        } else {
            state.withLock { $0.stats.framesDropped += 1 }
            return
        }

        var data = Data(count: length)
        let copied = data.withUnsafeMutableBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return -1 }
            return CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: base)
        }
        guard copied == noErr else {
            state.withLock { $0.stats.framesDropped += 1 }
            return
        }

        var frameFlags: LinkVideoFrameFlags = []
        if isKey { frameFlags.insert(.key) }
        if pending.refresh { frameFlags.insert(.refresh) }
        if ltrToken != nil { frameFlags.insert(.ltr) }
        let sequence = state.withLock { s -> UInt32 in
            let seq = s.sequence
            s.sequence &+= 1
            s.stats.framesEncoded += 1
            if reordered { s.stats.reorderedFrames += 1 }
            if let ltrToken {
                s.ltrTokens.append((seq, ltrToken))
                if s.ltrTokens.count > LinkLimits.maxLTRTokens { s.ltrTokens.removeFirst() }
            }
            s.latencies[s.latencyCount % s.latencies.count] = (now &- pending.submittedNanos) / 1000
            s.latencyCount += 1
            return seq
        }
        if let parameterSets { continuation.yield(.parameterSets(parameterSets)) }
        continuation.yield(.frame(LinkVideoFrame(window: settings.window, sequence: sequence, ptsMicros: pending.ptsMicros, flags: frameFlags, data: data)))
    }

    /// Extracts the parameter sets; nil when the stream does not use 4-byte NAL lengths or the sets exceed the link caps.
    static func parameterSets(from format: CMFormatDescription, codec: LinkVideoCodec) -> EncodedParameterSets? {
        var count = 0
        var headerLength: Int32 = 0
        var sets: [Data] = []
        let dims = CMVideoFormatDescriptionGetDimensions(format)

        func fetch(_ get: (Int, UnsafeMutablePointer<UnsafePointer<UInt8>?>, UnsafeMutablePointer<Int>, UnsafeMutablePointer<Int>, UnsafeMutablePointer<Int32>) -> OSStatus) -> Bool {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            guard get(0, &pointer, &size, &count, &headerLength) == noErr, count > 0, count <= LinkLimits.maxParameterSets else { return false }
            for i in 0..<count {
                guard get(i, &pointer, &size, &count, &headerLength) == noErr, let pointer, size > 0, size <= LinkLimits.maxParameterSetBytes else { return false }
                sets.append(Data(bytes: pointer, count: size))
            }
            return true
        }
        let ok: Bool
        switch codec {
        case .hevc:
            ok = fetch { CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, parameterSetIndex: $0, parameterSetPointerOut: $1, parameterSetSizeOut: $2, parameterSetCountOut: $3, nalUnitHeaderLengthOut: $4) }
        case .h264:
            ok = fetch { CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: $0, parameterSetPointerOut: $1, parameterSetSizeOut: $2, parameterSetCountOut: $3, nalUnitHeaderLengthOut: $4) }
        }
        guard ok, headerLength == 4 else { return nil }
        return EncodedParameterSets(codec: codec, sets: sets, width: Int(dims.width), height: Int(dims.height))
    }
}

#endif
