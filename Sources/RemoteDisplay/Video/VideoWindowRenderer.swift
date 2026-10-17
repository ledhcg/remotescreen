import CoreGraphics
import Foundation
import Metal
import RFBKit

/// Draws the decoded video of one window on the GPU: a `VideoSurface` for the main frame, optional child surfaces (menus, popovers) and the
/// local cursor, composed by a `SurfaceCompositor` with the geometry's `sourceRect` (the window's content inside the coded frame), zoom and pan.
///
/// A future `AppWindowView` owns one of these per window. Per display-link tick it calls `pull(from:)` and then `encode(into:...)`.
/// No UIKit dependency, so it can be tested on macOS by drawing to a texture.
@MainActor
public final class VideoWindowRenderer {
    public let compositor: SurfaceCompositor
    public let surface: VideoSurface
    public var device: MTLDevice { compositor.device }

    /// Surfaces drawn over the main frame, positioned in the main frame's pixels.
    public var children: [ChildSurface] = []

    /// Size in pixels of the current frame, `(0, 0)` before the first one. Feed it to `ViewportGeometry.updateRemoteSize`.
    public var frameSize: (width: Int, height: Int) { surface.size }
    /// Presentation timestamp of the frame on screen.
    public private(set) var presentedPTSMicros: UInt64?

    public init(device: MTLDevice, colorPixelFormat: MTLPixelFormat = .bgra8Unorm) throws {
        compositor = try SurfaceCompositor(device: device, colorPixelFormat: colorPixelFormat)
        surface = try VideoSurface(device: device)
    }

    /// Shows `frame`. Returns `false` (keeping the previous frame) if it cannot be mapped to textures.
    @discardableResult
    public func present(_ frame: DecodedVideoFrame) -> Bool {
        guard surface.update(frame.pixelBuffer) else { return false }
        presentedPTSMicros = frame.ptsMicros
        return true
    }

    /// Takes the newest frame from `decoder`, if there is one, and shows it. Returns `true` when the picture changed.
    @discardableResult
    public func pull(from decoder: VideoStreamDecoder) -> Bool {
        guard let frame = decoder.takeLatestFrame() else { return false }
        return present(frame)
    }

    /// Stops showing the video (window closed or stream restarting).
    public func clear() {
        surface.clear()
        presentedPTSMicros = nil
    }

    public func setCursor(_ cursor: CursorImage?) {
        compositor.setCursor(cursor)
    }

    /// Encodes the draw commands into `commandBuffer`. The caller presents and commits.
    /// - Parameters:
    ///   - geometry: `remoteSize` is the coded frame size (`frameSize`); `setSourceRect` selects the window content.
    ///   - pointer: pixel of the coded frame where the pointer is; `nil` draws no cursor.
    ///   - cornerRadius: radius in view points of the window picture's corners (children stay square). 0 = square.
    public func encode(
        into commandBuffer: MTLCommandBuffer,
        pass: MTLRenderPassDescriptor,
        geometry: ViewportGeometry,
        deviceScale: Double = 1,
        pointer: (x: Int, y: Int)? = nil,
        cornerRadius: Double = 0
    ) {
        compositor.encode(
            into: commandBuffer, pass: pass, main: surface, children: children, geometry: geometry, deviceScale: deviceScale, pointer: pointer,
            cornerRadius: cornerRadius
        )
    }

    /// Draws to an arbitrary texture and waits for the GPU. For tests and snapshots, not the draw loop.
    public func render(
        to target: MTLTexture,
        geometry: ViewportGeometry,
        deviceScale: Double = 1,
        pointer: (x: Int, y: Int)? = nil,
        clearColor: MTLClearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1),
        cornerRadius: Double = 0
    ) {
        compositor.render(
            to: target, main: surface, children: children, geometry: geometry, deviceScale: deviceScale, pointer: pointer, clearColor: clearColor,
            cornerRadius: cornerRadius
        )
    }

    public func makeCommandBuffer() -> MTLCommandBuffer? {
        compositor.makeCommandBuffer()
    }
}
