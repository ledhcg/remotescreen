import CoreGraphics
import CoreVideo
import Foundation
import Metal
import os
#if canImport(UIKit)
import UIKit
#endif

/// One `CVMetalTextureCache` per Metal device. Flushed every few hundred frames and on memory warnings, so IOSurface-backed textures of
/// decoded frames do not pile up.
final class VideoTextureCache: @unchecked Sendable {
    let cache: CVMetalTextureCache
    private let frames = OSAllocatedUnfairLock(initialState: 0)
    static let flushInterval = 240

    private static let registry = OSAllocatedUnfairLock(initialState: [UInt64: VideoTextureCache]())

    static func shared(for device: MTLDevice) throws -> VideoTextureCache {
        try registry.withLock { table in
            if let existing = table[device.registryID] { return existing }
            let created = try VideoTextureCache(device: device)
            table[device.registryID] = created
            return created
        }
    }

    private init(device: MTLDevice) throws {
        var created: CVMetalTextureCache?
        let status = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &created)
        guard status == kCVReturnSuccess, let created else { throw SurfaceError.textureCache(status) }
        cache = created
        #if canImport(UIKit)
        NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: nil) { [weak self] _ in
            self?.flush()
        }
        #endif
    }

    func flush() {
        CVMetalTextureCacheFlush(cache, 0)
    }

    /// Call once per new frame: flushes periodically.
    func noteFrame() {
        let due = frames.withLock { count -> Bool in
            count += 1
            if count >= Self.flushInterval { count = 0; return true }
            return false
        }
        if due { flush() }
    }
}

/// A decoded video frame (`CVPixelBuffer`, biplanar 4:2:0 video range) on the GPU through `CVMetalTextureCache` (no copy).
///
/// Only the newest frame is kept (latest wins). The `CVMetalTexture`s and the pixel buffer of a frame stay alive until every command buffer that
/// draws it has completed, so the decoder can recycle buffers without the GPU reading from them.
@MainActor
public final class VideoSurface: SurfaceTexture {
    /// Keeps the pixel buffer and its textures alive for as long as someone holds this object.
    private final class Frame: @unchecked Sendable {
        let pixelBuffer: CVPixelBuffer
        let lumaCV: CVMetalTexture
        let chromaCV: CVMetalTexture
        let luma: MTLTexture
        let chroma: MTLTexture

        init(pixelBuffer: CVPixelBuffer, lumaCV: CVMetalTexture, chromaCV: CVMetalTexture, luma: MTLTexture, chroma: MTLTexture) {
            self.pixelBuffer = pixelBuffer
            self.lumaCV = lumaCV
            self.chromaCV = chromaCV
            self.luma = luma
            self.chroma = chroma
        }
    }

    public let device: MTLDevice
    private let textureCache: VideoTextureCache
    private var frame: Frame?

    public private(set) var size: (width: Int, height: Int) = (0, 0)
    public private(set) var pixelLayout: SurfacePixelLayout = .ycbcr420(bitDepth: 8)

    public init(device: MTLDevice) throws {
        self.device = device
        textureCache = try VideoTextureCache.shared(for: device)
    }

    /// Makes `pixelBuffer` the frame to draw. Returns `false` (keeping the previous frame) when the format is not `420v` / `x420`
    /// or the buffer cannot be mapped to textures. The buffer should be Metal compatible (IOSurface-backed), as VideoToolbox output is.
    @discardableResult
    public func update(_ pixelBuffer: CVPixelBuffer) -> Bool {
        let bitDepth: Int
        let lumaFormat: MTLPixelFormat
        let chromaFormat: MTLPixelFormat
        switch CVPixelBufferGetPixelFormatType(pixelBuffer) {
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
            (bitDepth, lumaFormat, chromaFormat) = (8, .r8Unorm, .rg8Unorm)
        case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange:
            (bitDepth, lumaFormat, chromaFormat) = (10, .r16Unorm, .rg16Unorm)
        default:
            return false
        }
        guard CVPixelBufferGetPlaneCount(pixelBuffer) == 2 else { return false }

        func plane(_ index: Int, _ format: MTLPixelFormat) -> (CVMetalTexture, MTLTexture)? {
            var cvTexture: CVMetalTexture?
            let status = CVMetalTextureCacheCreateTextureFromImage(
                kCFAllocatorDefault, textureCache.cache, pixelBuffer, nil, format,
                CVPixelBufferGetWidthOfPlane(pixelBuffer, index), CVPixelBufferGetHeightOfPlane(pixelBuffer, index), index, &cvTexture
            )
            guard status == kCVReturnSuccess, let cvTexture, let texture = CVMetalTextureGetTexture(cvTexture) else { return nil }
            return (cvTexture, texture)
        }
        guard let (lumaCV, luma) = plane(0, lumaFormat), let (chromaCV, chroma) = plane(1, chromaFormat) else { return false }

        frame = Frame(pixelBuffer: pixelBuffer, lumaCV: lumaCV, chromaCV: chromaCV, luma: luma, chroma: chroma)
        size = (CVPixelBufferGetWidth(pixelBuffer), CVPixelBufferGetHeight(pixelBuffer))
        pixelLayout = .ycbcr420(bitDepth: bitDepth)
        textureCache.noteFrame()
        return true
    }

    /// Releases cached textures that are no longer in use (for example on a memory warning).
    public func flushCache() {
        textureCache.flush()
    }

    /// Drops the current frame (for example when the window closes).
    public func clear() {
        frame = nil
        size = (0, 0)
    }

    public func beginDraw(in commandBuffer: MTLCommandBuffer) -> SurfaceFrame? {
        guard let frame else { return nil }
        // The completion handler holds the frame (pixel buffer + CVMetalTextures) until the GPU is done with it.
        commandBuffer.addCompletedHandler { _ in withExtendedLifetime(frame) {} }
        return SurfaceFrame(primary: frame.luma, secondary: frame.chroma)
    }
}
