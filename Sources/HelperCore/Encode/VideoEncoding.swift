#if os(macOS)
import CoreVideo
import Foundation
import LinkProtocol

/// Which rate control the encoder session ended up with.
public enum EncoderRateControlMode: Sendable, Equatable {
    /// `kVTVideoEncoderSpecification_EnableLowLatencyRateControl` was accepted.
    case lowLatency
    /// The session could not be created with low-latency rate control; ordinary real-time rate control is used.
    case standard
}

/// What `VideoEncoder` negotiated with VideoToolbox. Reported once, right after creation (for diagnostics and spike S4).
public struct EncoderInfo: Sendable, Equatable {
    public var codec: LinkVideoCodec
    public var rateControl: EncoderRateControlMode
    public var hardwareAccelerated: Bool
    /// True when the macOS 26+ `VideoConferencing` compression preset was applied.
    public var usedVideoConferencingPreset: Bool
    /// True when long-term-reference loss recovery is available.
    public var longTermReferences: Bool
    public init(codec: LinkVideoCodec, rateControl: EncoderRateControlMode, hardwareAccelerated: Bool, usedVideoConferencingPreset: Bool, longTermReferences: Bool) {
        self.codec = codec; self.rateControl = rateControl; self.hardwareAccelerated = hardwareAccelerated
        self.usedVideoConferencingPreset = usedVideoConferencingPreset; self.longTermReferences = longTermReferences
    }
}

public struct EncoderSettings: Sendable, Equatable {
    public var window: WindowID
    public var preferredCodec: LinkVideoCodec
    public var width: Int
    public var height: Int
    public var bitrate: Int
    public var framesPerSecond: Int
    /// Seconds between forced key frames. Long on purpose: key frames are requested on demand (new subscriber, loss).
    public var maxKeyFrameIntervalSeconds: Double
    public var enableLongTermReferences: Bool
    public init(
        window: WindowID, preferredCodec: LinkVideoCodec = .hevc, width: Int, height: Int, bitrate: Int = 8_000_000,
        framesPerSecond: Int = 60, maxKeyFrameIntervalSeconds: Double = 30, enableLongTermReferences: Bool = true
    ) {
        self.window = window; self.preferredCodec = preferredCodec; self.width = width; self.height = height; self.bitrate = bitrate
        self.framesPerSecond = framesPerSecond; self.maxKeyFrameIntervalSeconds = maxKeyFrameIntervalSeconds
        self.enableLongTermReferences = enableLongTermReferences
    }
}

/// Per-frame request.
public struct EncodeOptions: Sendable, Equatable {
    public var forceKeyFrame = false
    /// Re-sync from the last acknowledged long-term reference (or an IDR when none was acknowledged).
    public var forceLTRRefresh = false
    public init(forceKeyFrame: Bool = false, forceLTRRefresh: Bool = false) {
        self.forceKeyFrame = forceKeyFrame; self.forceLTRRefresh = forceLTRRefresh
    }
}

/// Parameter sets of the stream, each without start code (VPS/SPS/PPS for HEVC, SPS/PPS for H.264).
public struct EncodedParameterSets: Sendable, Equatable {
    public var codec: LinkVideoCodec
    public var sets: [Data]
    public var width: Int
    public var height: Int
    public init(codec: LinkVideoCodec, sets: [Data], width: Int, height: Int) {
        self.codec = codec; self.sets = sets; self.width = width; self.height = height
    }

    /// The `video.config` message for this stream.
    public func makeConfig(window: WindowID, contentRect: LinkRect, scale: Double) -> LinkVideoConfig {
        LinkVideoConfig(
            window: window, codec: codec, parameterSets: sets, pixelWidth: UInt32(width), pixelHeight: UInt32(height),
            contentRect: contentRect, scale: scale)
    }
}

/// Output of an encoder, in order. A `.parameterSets` event always precedes the first frame that uses them.
public enum EncoderEvent: Sendable, Equatable {
    case parameterSets(EncodedParameterSets)
    /// `data` holds length-prefixed NAL units: each NAL unit is preceded by a 4-byte big-endian length (no Annex-B start
    /// codes). This is what VideoToolbox emits and what `VTDecompressionSession` / `AVSampleBufferDisplayLayer` consume
    /// directly on the iPad, so neither side rewrites the bitstream.
    case frame(LinkVideoFrame)
    /// An access unit exceeded `LinkLimits.maxVideoAccessUnitBytes` and was not sent; the encoder lowered its bitrate and
    /// will make the next frame a key frame.
    case oversizedDropped(bytes: Int)
}

public struct EncoderStats: Sendable, Equatable {
    public var framesEncoded = 0
    public var framesDropped = 0
    /// Frames whose decode time differs from the presentation time (must stay 0: no reordering).
    public var reorderedFrames = 0
    public var oversizedFrames = 0
    /// 95th percentile of submit-to-callback latency over the last 256 frames.
    public var latencyP95Micros: UInt64 = 0
    public init() {}
}

public enum VideoEncoderError: Error, Equatable {
    case sessionUnavailable
    case invalidSettings
    case encodeFailed(Int32)
    case invalidated
}

/// A video encoder for one window stream.
public protocol VideoEncoding: AnyObject, Sendable {
    var info: EncoderInfo { get }
    var events: AsyncStream<EncoderEvent> { get }
    var stats: EncoderStats { get }
    /// Submits one frame. Output arrives on `events`.
    func encode(_ pixelBuffer: CVPixelBuffer, ptsMicros: UInt64, options: EncodeOptions) throws
    func setTargets(bitrate: Int, framesPerSecond: Int)
    /// The client confirmed it holds these long-term reference frames. Tokens are frame sequence numbers.
    func acknowledgeLongTermReferences(sequences: [UInt32])
    /// Stops the encoder and finishes `events`.
    func invalidate()
}
#endif
