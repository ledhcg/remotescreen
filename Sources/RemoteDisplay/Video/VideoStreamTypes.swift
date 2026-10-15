import CoreVideo
import Foundation

/// Codec of a window's video stream. Protocol-neutral on purpose: `RemoteDisplay` does not know the link protocol, the transport maps its own
/// types to these.
public enum VideoCodec: Equatable, Sendable {
    case hevc
    case h264
}

/// What the decoder needs to build a decoding session: the parameter sets of the stream. A new config with different parameter sets
/// (resolution change, new encoder) makes the decoder rebuild its session and wait for a key frame.
public struct VideoStreamConfig: Equatable, Sendable {
    public var codec: VideoCodec
    /// VPS/SPS/PPS (HEVC) or SPS/PPS (H.264), each without start code.
    public var parameterSets: [Data]
    /// Size in bytes of the length prefix of every NAL unit in an access unit (4 for the helper's encoder).
    public var nalLengthSize: Int
    /// 8 decodes to `420v`, 10 (HEVC Main10) to `x420`.
    public var bitDepth: Int

    public init(codec: VideoCodec, parameterSets: [Data], nalLengthSize: Int = 4, bitDepth: Int = 8) {
        self.codec = codec
        self.parameterSets = parameterSets
        self.nalLengthSize = nalLengthSize
        self.bitDepth = bitDepth
    }
}

/// One encoded frame: length-prefixed NAL units exactly as the encoder produced them.
public struct VideoAccessUnit: Sendable {
    public var data: Data
    public var ptsMicros: UInt64
    public var isKey: Bool

    public init(data: Data, ptsMicros: UInt64, isKey: Bool) {
        self.data = data
        self.ptsMicros = ptsMicros
        self.isKey = isKey
    }
}

/// A decoded frame, ready for `VideoSurface`.
///
/// `@unchecked Sendable`: a `CVPixelBuffer` is a reference-counted CoreFoundation object that is thread-safe to retain and release. VideoToolbox
/// hands it over fully written and nobody mutates it afterwards (the decoder only drops its reference), so passing it between the decode
/// queue and the main actor is safe.
public struct DecodedVideoFrame: @unchecked Sendable {
    public let pixelBuffer: CVPixelBuffer
    public let ptsMicros: UInt64
    public var width: Int { CVPixelBufferGetWidth(pixelBuffer) }
    public var height: Int { CVPixelBufferGetHeight(pixelBuffer) }

    public init(pixelBuffer: CVPixelBuffer, ptsMicros: UInt64) {
        self.pixelBuffer = pixelBuffer
        self.ptsMicros = ptsMicros
    }
}

/// What `VideoStreamDecoder.decode` did with an access unit.
public enum VideoDecodeResult: Equatable, Sendable {
    /// Decoded and stored in the mailbox.
    case decoded
    /// A non-key frame while a key frame is needed: dropped without touching the decoder.
    case ignoredWaitingForKeyframe
    /// The access unit failed validation; a key frame is needed now.
    case rejectedMalformed
    /// The decoder failed (session invalid, bad data); the session was torn down and a key frame is needed.
    case failed
    /// No (valid) configuration yet.
    case notConfigured
    /// Suspended by `suspend()`.
    case suspended
}

public enum VideoStreamError: Error, Equatable, Sendable {
    case invalidParameterSets(String)
    case invalidNALLengthSize(Int)
    case invalidBitDepth(Int)
    case formatDescription(Int32)
    case invalidDimensions(width: Int, height: Int)
    case session(Int32)
}

/// Decode statistics, from a ring of the last decode times (no allocation per frame).
public struct VideoDecodeStats: Equatable, Sendable {
    public var framesDecoded = 0
    /// Frames replaced in the mailbox before anyone took them.
    public var framesDropped = 0
    /// Non-key frames skipped while waiting for a key frame, plus rejected access units.
    public var framesIgnored = 0
    public var sessionResets = 0
    /// Decode time of the recent frames, in milliseconds. `0` before the first frame.
    public var decodeP50Ms = 0.0
    public var decodeP95Ms = 0.0
}
