#if os(macOS)
import CoreMedia
import CoreVideo
import Foundation
import LinkProtocol

/// Screen Recording state as far as the helper can tell. macOS 27 may report remote-control capture under a separate
/// "Remote Desktop" privacy category that has no query API, so `.unknown` (not `.denied`) is the honest answer
/// whenever a failure does not clearly come from a missing grant; the UI should then guide the user to System Settings.
public enum CapturePermissionState: Sendable, Equatable {
    case granted
    case denied
    case unknown
}

/// `SCStreamFrameInfo.status`, decoupled from ScreenCaptureKit so fakes need no framework.
public enum CaptureFrameStatus: Sendable, Equatable {
    case complete, idle, blank, suspended, started, stopped
}

/// Per-frame facts taken from the `SCStreamFrameInfo` attachments.
public struct CaptureFrameMetadata: Sendable, Equatable {
    public var status: CaptureFrameStatus
    /// Where the window sits inside the output buffer, in output pixels.
    public var contentRect: LinkRect
    /// Factor by which the window was scaled to fit the output buffer (1 = not scaled).
    public var contentScale: Double
    /// Points to pixels of the display the window is on.
    public var scaleFactor: Double
    /// Regions that changed since the previous frame, in output pixels. Empty = nothing changed.
    public var dirtyRects: [LinkRect]
    public var ptsMicros: UInt64
    public init(
        status: CaptureFrameStatus, contentRect: LinkRect, contentScale: Double = 1, scaleFactor: Double = 2,
        dirtyRects: [LinkRect] = [], ptsMicros: UInt64 = 0
    ) {
        self.status = status; self.contentRect = contentRect; self.contentScale = contentScale
        self.scaleFactor = scaleFactor; self.dirtyRects = dirtyRects; self.ptsMicros = ptsMicros
    }

    /// The window's native size in pixels (undoing the capture-side downscale).
    public var nativePixelSize: LinkSize {
        let s = contentScale > 0 ? contentScale : 1
        return LinkSize(width: (contentRect.size.width / s).rounded(), height: (contentRect.size.height / s).rounded())
    }
}

/// A captured frame. `CVPixelBuffer` is not `Sendable`, but a capture buffer is handed over exactly once (producer
/// callback to consumer) and never mutated afterwards, so sharing the reference across isolation domains is safe.
public struct CapturedFrame: @unchecked Sendable {
    /// `nil` for status-only callbacks (idle, blank) which carry no image.
    public let pixelBuffer: CVPixelBuffer?
    public let metadata: CaptureFrameMetadata
    public init(pixelBuffer: CVPixelBuffer?, metadata: CaptureFrameMetadata) {
        self.pixelBuffer = pixelBuffer; self.metadata = metadata
    }
}

/// What a subscriber asks for. The target size is the iPad scene's pixel size: the Mac never upscales beyond the window.
public struct CaptureRequest: Sendable, Equatable {
    public var targetPixelWidth: UInt32
    public var targetPixelHeight: UInt32
    public var framesPerSecond: Int
    public init(targetPixelWidth: UInt32, targetPixelHeight: UInt32, framesPerSecond: Int) {
        self.targetPixelWidth = targetPixelWidth; self.targetPixelHeight = targetPixelHeight; self.framesPerSecond = framesPerSecond
    }
}

/// Concrete stream parameters derived from a request and the window's size.
public struct CaptureStreamConfig: Sendable, Equatable {
    public var window: WindowID
    public var outputWidth: Int
    public var outputHeight: Int
    public var framesPerSecond: Int
    public init(window: WindowID, outputWidth: Int, outputHeight: Int, framesPerSecond: Int) {
        self.window = window; self.outputWidth = outputWidth; self.outputHeight = outputHeight; self.framesPerSecond = framesPerSecond
    }
}

/// Raw output of one OS stream.
public enum CaptureStreamOutput: Sendable {
    case frame(CapturedFrame)
    /// The stream ended. `nil` = the engine asked for it.
    case stopped(CaptureSystemError?)
}

/// A failure reported by a `CaptureSystem`, reduced to what the engine needs to decide on a restart.
public struct CaptureSystemError: Error, Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case permissionDenied
        case windowGone
        case stoppedByUser
        case other
    }
    public var kind: Kind
    public var code: Int
    public var message: String
    public init(kind: Kind, code: Int = 0, message: String = "") { self.kind = kind; self.code = code; self.message = message }
}

/// Why a subscription ended for good.
public enum CaptureFailure: Sendable, Equatable {
    case permission(CapturePermissionState)
    case windowGone
    case stoppedByUser
    /// Restarts were exhausted.
    case exhausted(lastCode: Int)
}

/// Events the engine delivers to a subscriber.
public enum CaptureEvent: Sendable {
    case frame(CapturedFrame)
    /// The window's native pixel size changed and the stream was reconfigured to this output size.
    case resized(CaptureStreamConfig)
    /// Nothing changed for a while: time for one high-quality refresh frame.
    case idle
    /// Content changed again after `idle`.
    case active
    case restarting(attempt: Int)
    case failed(CaptureFailure)
}

/// One live OS stream.
public protocol CaptureStreamHandle: Sendable {
    func update(_ config: CaptureStreamConfig) async throws
    func stop() async
}

/// The OS-facing seam. The real implementation uses ScreenCaptureKit; tests use a fake.
public protocol CaptureSystem: Sendable {
    /// Starts a stream. Outputs are delivered by calling `output` from any thread, in order.
    func startStream(
        config: CaptureStreamConfig, output: @escaping @Sendable (CaptureStreamOutput) -> Void
    ) async throws -> any CaptureStreamHandle
}

/// Pure sizing and error rules.
public enum CaptureSizing {
    /// Output size for a window of `native` pixels: never larger than the window, capped to the target keeping aspect
    /// ratio, rounded down to even numbers (4:2:0 needs them), at least 2x2.
    public static func outputSize(native: LinkSize, request: CaptureRequest) -> (width: Int, height: Int) {
        let nw = max(native.width, 1), nh = max(native.height, 1)
        var factor = 1.0
        if request.targetPixelWidth > 0 { factor = min(factor, Double(request.targetPixelWidth) / nw) }
        if request.targetPixelHeight > 0 { factor = min(factor, Double(request.targetPixelHeight) / nh) }
        let cap = Double(LinkLimits.maxPixelDimension)
        func even(_ v: Double) -> Int { max(2, Int(min(v, cap)) & ~1) }
        return (even(nw * factor), even(nh * factor))
    }

    /// Classifies a ScreenCaptureKit error code (domain `com.apple.ScreenCaptureKit.SCStreamErrorDomain`).
    /// -3801 userDeclined and -3803 missingEntitlements mean the grant is missing; -3817 userStopped is the menu-bar stop
    /// button; -3806 and -3813...-3815 mean the window or its source vanished; everything else is worth a restart.
    public static func classify(scStreamErrorCode code: Int, message: String = "") -> CaptureSystemError {
        switch code {
        case -3801, -3803: return CaptureSystemError(kind: .permissionDenied, code: code, message: message)
        case -3817: return CaptureSystemError(kind: .stoppedByUser, code: code, message: message)
        case -3813, -3814, -3815, -3806: return CaptureSystemError(kind: .windowGone, code: code, message: message)
        default: return CaptureSystemError(kind: .other, code: code, message: message)
        }
    }

    /// Permission state implied by a failure.
    public static func permissionState(for error: CaptureSystemError) -> CapturePermissionState {
        error.kind == .permissionDenied ? .denied : .unknown
    }
}
#endif
