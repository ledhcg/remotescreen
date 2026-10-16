#if os(macOS)
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import LinkProtocol
import os
@preconcurrency import ScreenCaptureKit

/// Per-window `SCStream` capture. Not exercised by `swift test` (needs the Screen Recording grant); validated by spike S3.
public struct ScreenCaptureKitSystem: CaptureSystem {
    public init() {}

    /// Cheap, non-prompting check of the Screen Recording grant.
    public static func preflightPermission() -> CapturePermissionState {
        CGPreflightScreenCaptureAccess() ? .granted : .denied
    }

    public func startStream(
        config: CaptureStreamConfig, output: @escaping @Sendable (CaptureStreamOutput) -> Void
    ) async throws -> any CaptureStreamHandle {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        } catch {
            throw Self.map(error)
        }
        guard let number = config.windowNumber, let window = content.windows.first(where: { $0.windowID == number }) else {
            throw CaptureSystemError(kind: .windowGone, message: "window not in shareable content")
        }
        // Independent-window filter: the window stays live while covered or on another Space.
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let streamConfig = Self.makeConfiguration(for: config)
        let sink = StreamSink(output: output)
        let stream = SCStream(filter: filter, configuration: streamConfig, delegate: sink)
        do {
            try stream.addStreamOutput(sink, type: .screen, sampleHandlerQueue: sink.queue)
            try await stream.startCapture()
        } catch {
            throw Self.map(error)
        }
        return Handle(stream: stream, sink: sink)
    }

    // MARK: Configuration

    static func makeConfiguration(for config: CaptureStreamConfig) -> SCStreamConfiguration {
        let c = SCStreamConfiguration()
        apply(config, to: c)
        c.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange  // 420v
        c.queueDepth = 3
        c.captureResolution = .best
        c.showsCursor = false  // the iPad draws the pointer
        c.ignoreShadowsSingleWindow = true
        c.ignoreGlobalClipSingleWindow = true
        c.shouldBeOpaque = true
        // The transparent rounded corners of the window are filled with this colour; the iPad letterboxes with the same black, so
        // the corners blend in instead of showing as wedges. The property is `assign` in Objective-C (not retained): it must be a
        // colour that lives for the whole process. A temporary `CGColor(gray:alpha:)` was freed at once, and SCStream's copy of the
        // configuration then crashed the helper on every window subscription (0.3.0 build 4).
        c.backgroundColor = CGColor.black
        if #available(macOS 14.2, *) { c.includeChildWindows = true }
        c.colorSpaceName = CGColorSpace.sRGB
        c.colorMatrix = CGDisplayStream.yCbCrMatrix_ITU_R_709_2
        c.capturesAudio = false
        return c
    }

    static func apply(_ config: CaptureStreamConfig, to c: SCStreamConfiguration) {
        c.width = config.outputWidth
        c.height = config.outputHeight
        let fps = max(1, min(config.framesPerSecond, Int(LinkLimits.maxFramesPerSecond)))
        c.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
    }

    // MARK: Errors

    static func map(_ error: Error) -> CaptureSystemError {
        if let known = error as? CaptureSystemError { return known }
        let ns = error as NSError
        return CaptureSizing.classify(scStreamErrorCode: ns.code, message: ns.domain)
    }

    // MARK: Handle and sink

    private final class Handle: CaptureStreamHandle, @unchecked Sendable {
        // SCStream is not Sendable; calls are serialised by the engine actor, which is the only user.
        private let stream: SCStream
        private let sink: StreamSink
        init(stream: SCStream, sink: StreamSink) { self.stream = stream; self.sink = sink }

        func update(_ config: CaptureStreamConfig) async throws {
            let c = ScreenCaptureKitSystem.makeConfiguration(for: config)
            do { try await stream.updateConfiguration(c) } catch { throw ScreenCaptureKitSystem.map(error) }
        }

        func stop() async {
            sink.markStopping()
            try? await stream.stopCapture()
            try? stream.removeStreamOutput(sink, type: .screen)
        }
    }

    private final class StreamSink: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
        let queue = DispatchQueue(label: "com.screon.helper.capture", qos: .userInteractive)
        private let output: @Sendable (CaptureStreamOutput) -> Void
        private let stopping = OSAllocatedUnfairLock(initialState: false)
        private let samples = OSAllocatedUnfairLock(initialState: 0)
        private static let log = Logger(subsystem: "app.screon.helper", category: "capture")

        init(output: @escaping @Sendable (CaptureStreamOutput) -> Void) { self.output = output }

        func markStopping() { stopping.withLock { $0 = true } }

        func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
            guard type == .screen, CMSampleBufferIsValid(sampleBuffer) else { return }
            let count = samples.withLock { $0 += 1; return $0 }
            let meta = Self.metadata(from: sampleBuffer)
            if count <= 3 || count == 30 {
                Self.log.debug("capture sample \(count, privacy: .public): status \(meta.map { String(describing: $0.status) } ?? "unreadable", privacy: .public), image \(CMSampleBufferGetImageBuffer(sampleBuffer) != nil, privacy: .public)")
            }
            guard let meta else { return }
            let image = CMSampleBufferGetImageBuffer(sampleBuffer)
            output(.frame(CapturedFrame(pixelBuffer: image, metadata: meta)))
        }

        func stream(_ stream: SCStream, didStopWithError error: Error) {
            if stopping.withLock({ $0 }) { return }
            output(.stopped(ScreenCaptureKitSystem.map(error)))
        }

        static func metadata(from sampleBuffer: CMSampleBuffer) -> CaptureFrameMetadata? {
            guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                  let info = attachments.first
            else { return nil }
            let status: CaptureFrameStatus
            switch (info[.status] as? Int).flatMap(SCFrameStatus.init(rawValue:)) {
            case .complete: status = .complete
            case .idle: status = .idle
            case .blank: status = .blank
            case .suspended: status = .suspended
            case .started: status = .started
            case .stopped: status = .stopped
            default: return nil
            }
            func rect(_ any: Any?) -> LinkRect? {
                guard let dict = any as? NSDictionary, let r = CGRect(dictionaryRepresentation: dict as CFDictionary) else { return nil }
                return LinkRect(x: r.origin.x, y: r.origin.y, width: r.width, height: r.height)
            }
            let contentRect = rect(info[.contentRect]) ?? LinkRect(x: 0, y: 0, width: 0, height: 0)
            let dirty = (info[.dirtyRects] as? [Any])?.compactMap(rect) ?? []
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            let micros = pts.isNumeric ? UInt64(max(0, CMTimeConvertScale(pts, timescale: 1_000_000, method: .default).value)) : 0
            return CaptureFrameMetadata(
                status: status, contentRect: contentRect,
                contentScale: (info[.contentScale] as? Double) ?? 1, scaleFactor: (info[.scaleFactor] as? Double) ?? 1,
                dirtyRects: dirty, ptsMicros: micros)
        }
    }
}
#endif
