import CoreGraphics
import Foundation
import Metal
import RFBKit

/// Draws the Mac's `Framebuffer` on the GPU using Metal: a facade over one `FramebufferSurface` (BGRA dual-texture upload) and a
/// `SurfaceCompositor` (shaders, cursor, geometry). Kept so the RFB view has a single object to talk to; the app-window path
/// uses the surfaces and the compositor directly.
///
/// No UIKit dependency, so it runs and can be tested on macOS by drawing to a texture and reading it back.
@MainActor
public final class FramebufferRenderer {
    public typealias RendererError = SurfaceError

    public var device: MTLDevice { compositor.device }
    public let surface: FramebufferSurface
    public let compositor: SurfaceCompositor

    /// Current texture size, `(0, 0)` if there is no data yet.
    public var textureSize: (width: Int, height: Int) { surface.size }

    public init(device: MTLDevice, colorPixelFormat: MTLPixelFormat = .bgra8Unorm) throws {
        compositor = try SurfaceCompositor(device: device, colorPixelFormat: colorPixelFormat)
        surface = FramebufferSurface(device: device)
    }

    /// Pushes the changed regions of `framebuffer` to the texture. `dirty == nil` means push everything.
    /// The texture is recreated (and fully uploaded) when the remote screen size changes.
    public func upload(_ framebuffer: Framebuffer, dirty: [PixelRect]? = nil) {
        surface.upload(framebuffer, dirty: dirty)
    }

    /// Number of draw commands pending on the GPU for the two textures (for tests).
    var inFlightCounts: [Int] { surface.inFlightCounts }

    /// Sets the cursor image. `nil` or an empty image (the server hides the cursor) draws no cursor.
    public func setCursor(_ cursor: CursorImage?) {
        compositor.setCursor(cursor)
    }

    /// Encodes the draw commands into `commandBuffer` with the given pass. The caller presents and commits.
    /// - Parameters:
    ///   - deviceScale: device pixels per point (`UIScreen.scale`), used to choose the sampler.
    ///   - pointer: Mac pixel where the pointer is. `nil` draws no cursor (its position is not yet known).
    ///   - cornerRadius: radius in view points of the picture's corners; the corners show the clear colour. 0 = square.
    public func encode(
        into commandBuffer: MTLCommandBuffer,
        pass: MTLRenderPassDescriptor,
        geometry: ViewportGeometry,
        deviceScale: Double = 1,
        pointer: (x: Int, y: Int)? = nil,
        cornerRadius: Double = 0
    ) {
        compositor.encode(
            into: commandBuffer, pass: pass, main: surface, geometry: geometry, deviceScale: deviceScale, pointer: pointer,
            cornerRadius: cornerRadius
        )
    }

    /// Draws to an arbitrary texture and waits for the GPU to finish. Used for tests and screenshots, not in the view's draw loop.
    public func render(
        to target: MTLTexture,
        geometry: ViewportGeometry,
        deviceScale: Double = 1,
        pointer: (x: Int, y: Int)? = nil,
        clearColor: MTLClearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1),
        cornerRadius: Double = 0
    ) {
        compositor.render(
            to: target, main: surface, geometry: geometry, deviceScale: deviceScale, pointer: pointer, clearColor: clearColor,
            cornerRadius: cornerRadius
        )
    }

    /// Command queue, shared with `MTKView`.
    public func makeCommandBuffer() -> MTLCommandBuffer? {
        compositor.makeCommandBuffer()
    }
}
