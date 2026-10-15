import CoreGraphics
import Foundation
import Metal

/// How the pixels of a surface are laid out in GPU textures.
public enum SurfacePixelLayout: Equatable, Sendable {
    /// One BGRA texture (the RFB framebuffer, snapshots).
    case bgra
    /// Two textures: luma (R) and interleaved chroma (RG, half resolution), video range, BT.709. `bitDepth` is 8 (`420v`) or 10 (`x420`).
    case ycbcr420(bitDepth: Int)
}

/// The textures that hold one frame of a surface, valid for the command buffer passed to `SurfaceTexture.beginDraw`.
public struct SurfaceFrame {
    /// BGRA texture, or the luma plane.
    public let primary: MTLTexture
    /// Chroma plane for `.ycbcr420`, `nil` for `.bgra`.
    public let secondary: MTLTexture?

    public init(primary: MTLTexture, secondary: MTLTexture? = nil) {
        self.primary = primary
        self.secondary = secondary
    }
}

/// Something the compositor can draw: a size, a pixel layout and the textures of its current frame.
@MainActor
public protocol SurfaceTexture: AnyObject {
    /// Size in pixels, `(0, 0)` if there is no frame yet.
    var size: (width: Int, height: Int) { get }
    var pixelLayout: SurfacePixelLayout { get }
    /// Returns the textures for the current frame and keeps them valid until `commandBuffer` completes (so the next update never
    /// overwrites or releases what the GPU is still reading). `nil` when there is no frame to draw.
    func beginDraw(in commandBuffer: MTLCommandBuffer) -> SurfaceFrame?
}

/// A surface drawn on top of the main one at an offset given in the main surface's pixels (menus, popovers, sheets).
public struct ChildSurface {
    public var surface: any SurfaceTexture
    /// Top-left corner relative to the main surface's top-left corner, in source pixels.
    public var offset: CGPoint
    /// Sub-rectangle of the child to draw, normalized (0...1). `nil` draws all of it.
    public var uvRect: CGRect?

    public init(surface: any SurfaceTexture, offset: CGPoint, uvRect: CGRect? = nil) {
        self.surface = surface
        self.offset = offset
        self.uvRect = uvRect
    }
}

public enum SurfaceError: Error, Equatable {
    case noCommandQueue
    case shader(String)
    case pipeline(String)
    case textureCache(Int32)
}
