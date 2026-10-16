import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox
import os

/// State shared between the decode caller and VideoToolbox's output callback: the single-slot mailbox, counters and the decode-time ring.
/// All of it is behind one unfair lock; nothing in here allocates per frame (the ring is a fixed buffer).
private final class DecoderShared: @unchecked Sendable {
    static let ringCapacity = 256

    struct State {
        var latest: DecodedVideoFrame?
        var callbackStatus: OSStatus = noErr
        var needsKeyframe = true
        var suspended = false
        var decoded = 0
        var dropped = 0
        var ignored = 0
        var resets = 0
        var ringCount = 0
        var ringHead = 0
    }

    let lock = OSAllocatedUnfairLock(initialState: State())
    /// Decode times in microseconds. Allocated once, written in place under `lock`.
    private let ring = UnsafeMutablePointer<UInt32>.allocate(capacity: ringCapacity)

    init() { ring.initialize(repeating: 0, count: Self.ringCapacity) }
    deinit { ring.deallocate() }

    func recordDecodeTime(micros: UInt32) {
        lock.withLock { state in
            ring[state.ringHead] = micros
            state.ringHead = (state.ringHead + 1) % Self.ringCapacity
            state.ringCount = min(state.ringCount + 1, Self.ringCapacity)
        }
    }

    func percentiles() -> (p50: Double, p95: Double) {
        let samples: [UInt32] = lock.withLock { state in
            Array(UnsafeBufferPointer(start: ring, count: state.ringCount))
        }
        guard !samples.isEmpty else { return (0, 0) }
        let sorted = samples.sorted()
        func at(_ q: Double) -> Double { Double(sorted[min(sorted.count - 1, Int(Double(sorted.count) * q))]) / 1000 }
        return (at(0.5), at(0.95))
    }
}

/// VideoToolbox output callback. `refcon` is the unretained `DecoderShared`, which the decoder keeps alive until after the session is invalidated.
private let decoderOutputCallback: VTDecompressionOutputCallback = { refcon, _, status, _, imageBuffer, pts, _ in
    guard let refcon else { return }
    let shared = Unmanaged<DecoderShared>.fromOpaque(refcon).takeUnretainedValue()
    var frame: DecodedVideoFrame?
    var failure: OSStatus = status
    if status == noErr, let imageBuffer {
        let width = CVPixelBufferGetWidth(imageBuffer), height = CVPixelBufferGetHeight(imageBuffer)
        if AccessUnitParser.validateDimensions(width: width, height: height) {
            let micros = pts.timescale == 1_000_000 && pts.value >= 0 ? UInt64(pts.value) : 0
            frame = DecodedVideoFrame(pixelBuffer: imageBuffer, ptsMicros: micros)
        } else {
            failure = kVTVideoDecoderMalfunctionErr
        }
    }
    shared.lock.withLock { [frame, failure] state in
        guard let frame else {
            if failure != noErr { state.callbackStatus = failure }
            return
        }
        if state.latest != nil { state.dropped += 1 } // latest wins: the unconsumed frame is replaced
        state.latest = frame
        state.decoded += 1
    }
}

/// Decodes the HEVC / H.264 stream of one window with VideoToolbox.
///
/// One instance per window stream. `decode(_:)` is meant to be called from one decode queue (it is serialized anyway); the newest decoded frame
/// is picked up from any thread with `takeLatestFrame()` (a single-slot mailbox: a frame nobody took is replaced by the next one and counted
/// as dropped). Any error tears the session down, sets `needsKeyframe` and calls `onNeedsKeyframe` so the transport can ask the helper for a
/// key frame; until one arrives, non-key frames are ignored.
public final class VideoStreamDecoder: @unchecked Sendable { // @unchecked: session state is guarded by `lifecycle`, shared state by DecoderShared's lock.
    private let shared = DecoderShared()
    private let lifecycle = NSLock()
    // Guarded by `lifecycle`.
    private var config: VideoStreamConfig?
    private var format: CMVideoFormatDescription?
    private var session: VTDecompressionSession?
    private var dimensions: (width: Int, height: Int) = (0, 0)

    private let signposter = OSSignposter(subsystem: "app.screon.remotedisplay", category: "video")

    /// Called (from the decoding thread, outside any lock) whenever the decoder needs a key frame: after an error, a rejected access unit, or
    /// `resume()`. The transport should send `stream.keyframe`; it should rate-limit, since a stream of bad key frames calls this repeatedly.
    public var onNeedsKeyframe: (@Sendable () -> Void)? {
        get { callbacks.withLock { $0.needsKeyframe } }
        set { callbacks.withLock { $0.needsKeyframe = newValue } }
    }
    /// Called when a new frame is in the mailbox (from the decoding thread). Use it to wake the display link; the frame itself is taken with `takeLatestFrame()`.
    public var onFrameAvailable: (@Sendable () -> Void)? {
        get { callbacks.withLock { $0.frameAvailable } }
        set { callbacks.withLock { $0.frameAvailable = newValue } }
    }
    private struct Callbacks {
        var needsKeyframe: (@Sendable () -> Void)?
        var frameAvailable: (@Sendable () -> Void)?
    }
    private let callbacks = OSAllocatedUnfairLock(initialState: Callbacks())

    public init() {}

    deinit {
        tearDownSession()
    }

    // MARK: State

    /// `true` until a key frame has been decoded after a (re)configuration, error or resume.
    public var needsKeyframe: Bool { shared.lock.withLock { $0.needsKeyframe } }
    public var isSuspended: Bool { shared.lock.withLock { $0.suspended } }
    /// Pixel size of the stream from the current parameter sets, `(0, 0)` when not configured.
    public var streamSize: (width: Int, height: Int) { lifecycle.withLock { dimensions } }
    public var currentConfig: VideoStreamConfig? { lifecycle.withLock { config } }

    public var stats: VideoDecodeStats {
        let (p50, p95) = shared.percentiles()
        return shared.lock.withLock { state in
            VideoDecodeStats(
                framesDecoded: state.decoded, framesDropped: state.dropped, framesIgnored: state.ignored, sessionResets: state.resets,
                decodeP50Ms: p50, decodeP95Ms: p95
            )
        }
    }

    /// Takes the newest decoded frame, leaving the mailbox empty. `nil` if there is no new frame since the last call.
    public func takeLatestFrame() -> DecodedVideoFrame? {
        shared.lock.withLock { state in
            defer { state.latest = nil }
            return state.latest
        }
    }

    // MARK: Configuration

    /// Sets the parameter sets of the stream. The same sets again change nothing. Different ones drop the old session and wait for a key frame.
    /// Throws (and leaves the decoder unconfigured) when the sets are invalid or describe an unreasonable size.
    public func configure(_ newConfig: VideoStreamConfig) throws {
        try AccessUnitParser.validate(newConfig)
        try lifecycle.withLock {
            if newConfig == config, format != nil { return }
            tearDownSessionLocked()
            config = nil
            format = nil
            dimensions = (0, 0)
            let description = try Self.makeFormatDescription(newConfig)
            let size = CMVideoFormatDescriptionGetDimensions(description)
            guard AccessUnitParser.validateDimensions(width: Int(size.width), height: Int(size.height)) else {
                throw VideoStreamError.invalidDimensions(width: Int(size.width), height: Int(size.height))
            }
            config = newConfig
            format = description
            dimensions = (Int(size.width), Int(size.height))
            shared.lock.withLock {
                $0.needsKeyframe = true
                $0.latest = nil
            }
        }
    }

    /// Builds the format description. The parameter set pointers must stay valid for the whole call: they point into `blob`, which outlives it
    /// (a Release-only bug source when pointers are taken from temporaries).
    private static func makeFormatDescription(_ config: VideoStreamConfig) throws -> CMVideoFormatDescription {
        var blob = [UInt8]()
        var sizes = [Int]()
        for set in config.parameterSets {
            sizes.append(set.count)
            blob.append(contentsOf: set)
        }
        var description: CMVideoFormatDescription?
        let status: OSStatus = blob.withUnsafeBufferPointer { buffer -> OSStatus in
            guard let base = buffer.baseAddress else { return kCMFormatDescriptionError_InvalidParameter }
            var pointers = [UnsafePointer<UInt8>]()
            var offset = 0
            for size in sizes {
                pointers.append(base + offset)
                offset += size
            }
            return pointers.withUnsafeBufferPointer { pointerBuffer in
                sizes.withUnsafeBufferPointer { sizeBuffer in
                    switch config.codec {
                    case .hevc:
                        return CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                            allocator: kCFAllocatorDefault, parameterSetCount: sizes.count,
                            parameterSetPointers: pointerBuffer.baseAddress!, parameterSetSizes: sizeBuffer.baseAddress!,
                            nalUnitHeaderLength: Int32(config.nalLengthSize), extensions: nil, formatDescriptionOut: &description
                        )
                    case .h264:
                        return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                            allocator: kCFAllocatorDefault, parameterSetCount: sizes.count,
                            parameterSetPointers: pointerBuffer.baseAddress!, parameterSetSizes: sizeBuffer.baseAddress!,
                            nalUnitHeaderLength: Int32(config.nalLengthSize), formatDescriptionOut: &description
                        )
                    }
                }
            }
        }
        guard status == noErr, let description else { throw VideoStreamError.formatDescription(status) }
        return description
    }

    // MARK: Lifecycle

    /// The scene went to the background: VideoToolbox sessions do not survive it. Invalidates the session and drops buffered frames.
    public func suspend() {
        lifecycle.withLock {
            tearDownSessionLocked()
            shared.lock.withLock {
                $0.suspended = true
                $0.needsKeyframe = true
                $0.latest = nil
            }
        }
    }

    /// The scene is active again. A key frame is required before anything is shown; `onNeedsKeyframe` is called so the transport requests it.
    public func resume() {
        let wasSuspended = shared.lock.withLock { state -> Bool in
            let was = state.suspended
            state.suspended = false
            state.needsKeyframe = true
            return was
        }
        if wasSuspended { onNeedsKeyframe?() }
    }

    /// Drops the session and any frame (window closed).
    public func reset() {
        lifecycle.withLock {
            tearDownSessionLocked()
            config = nil
            format = nil
            dimensions = (0, 0)
            shared.lock.withLock {
                $0.latest = nil
                $0.needsKeyframe = true
            }
        }
    }

    // MARK: Decoding

    @discardableResult
    public func decode(_ unit: VideoAccessUnit) -> VideoDecodeResult {
        let (result, wantKeyframe, gotFrame) = lifecycle.withLock { decodeLocked(unit) }
        if wantKeyframe { onNeedsKeyframe?() }
        if gotFrame { onFrameAvailable?() }
        return result
    }

    private func decodeLocked(_ unit: VideoAccessUnit) -> (VideoDecodeResult, wantKeyframe: Bool, gotFrame: Bool) {
        let (suspended, needsKey) = shared.lock.withLock { ($0.suspended, $0.needsKeyframe) }
        if suspended { return (.suspended, false, false) }
        guard let config, let format else { return (.notConfigured, false, false) }
        if needsKey, !unit.isKey {
            shared.lock.withLock { $0.ignored += 1 }
            // Keep asking while deltas arrive: a single request can be lost (the key frame dropped by the Mac before its stream
            // config went out, a request sent while the stream was being replaced), and a window whose content does not change
            // would then stay frozen until the encoder's periodic key frame. The owner rate-limits (`KeyframeRequester`).
            return (.ignoredWaitingForKeyframe, true, false)
        }

        // Validate before anything is allocated or handed to VideoToolbox, which trusts the lengths.
        if case .failure = AccessUnitParser.validate(unit.data, lengthSize: config.nalLengthSize) {
            return (.rejectedMalformed, fail(resetSession: false, countAsIgnored: true), false)
        }

        if session == nil {
            // Only a key frame can start a fresh session (guaranteed above: a missing session implies needsKeyframe).
            do { try createSession(format: format, bitDepth: config.bitDepth) } catch {
                return (.failed, fail(resetSession: true, countAsIgnored: false), false)
            }
        }
        guard let session, let sample = Self.makeSampleBuffer(unit, format: format) else {
            return (.failed, fail(resetSession: true, countAsIgnored: false), false)
        }

        let signpostID = signposter.makeSignpostID()
        let interval = signposter.beginInterval("decode", id: signpostID)
        let start = DispatchTime.now().uptimeNanoseconds
        var status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], frameRefcon: nil, infoFlagsOut: nil)
        if status == noErr { status = VTDecompressionSessionWaitForAsynchronousFrames(session) }
        let elapsedMicros = (DispatchTime.now().uptimeNanoseconds &- start) / 1000
        signposter.endInterval("decode", interval)

        let callbackStatus = shared.lock.withLock { state -> OSStatus in
            defer { state.callbackStatus = noErr }
            return state.callbackStatus
        }
        if status != noErr || callbackStatus != noErr {
            return (.failed, fail(resetSession: true, countAsIgnored: false), false)
        }
        shared.recordDecodeTime(micros: UInt32(clamping: elapsedMicros))
        let gotFrame = shared.lock.withLock { state -> Bool in
            state.needsKeyframe = false
            return state.latest != nil
        }
        return (.decoded, false, gotFrame)
    }

    /// Records a failure. Returns `true`: the caller must ask for a key frame.
    private func fail(resetSession: Bool, countAsIgnored: Bool) -> Bool {
        if resetSession { tearDownSessionLocked() }
        shared.lock.withLock { state in
            state.needsKeyframe = true
            if countAsIgnored { state.ignored += 1 }
        }
        return true
    }

    private func createSession(format: CMVideoFormatDescription, bitDepth: Int) throws {
        let pixelFormat = bitDepth == 10 ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: pixelFormat,
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [String: Any](),
        ]
        var record = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: decoderOutputCallback, decompressionOutputRefCon: Unmanaged.passUnretained(shared).toOpaque()
        )
        var created: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault, formatDescription: format, decoderSpecification: nil,
            imageBufferAttributes: attributes as CFDictionary, outputCallback: &record, decompressionSessionOut: &created
        )
        guard status == noErr, let created else { throw VideoStreamError.session(status) }
        VTSessionSetProperty(created, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        session = created
        shared.lock.withLock { $0.resets += 1 }
    }

    /// One copy of the access unit into a `CMBlockBuffer` (the buffer must own its memory: `Data` gives no stable pointer).
    private static func makeSampleBuffer(_ unit: VideoAccessUnit, format: CMVideoFormatDescription) -> CMSampleBuffer? {
        let length = unit.data.count
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: length, blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil, offsetToData: 0, dataLength: length, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block
        ) == noErr, let block else { return nil }
        let copied = unit.data.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return kCMBlockBufferBadPointerParameterErr }
            return CMBlockBufferReplaceDataBytes(with: base, blockBuffer: block, offsetIntoDestination: 0, dataLength: length)
        }
        guard copied == noErr else { return nil }
        var timing = CMSampleTimingInfo(
            duration: .invalid, presentationTimeStamp: CMTime(value: CMTimeValue(clamping: unit.ptsMicros), timescale: 1_000_000), decodeTimeStamp: .invalid
        )
        var sampleSize = length
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: 1,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize, sampleBufferOut: &sample
        ) == noErr else { return nil }
        return sample
    }

    private func tearDownSession() {
        lifecycle.withLock { tearDownSessionLocked() }
    }

    private func tearDownSessionLocked() {
        guard let session else { return }
        VTDecompressionSessionWaitForAsynchronousFrames(session)
        VTDecompressionSessionInvalidate(session)
        self.session = nil
    }
}
