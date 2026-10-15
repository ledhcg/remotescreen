import CoreGraphics
import Foundation
import Metal
import os
import RFBKit

/// The RFB framebuffer on the GPU.
///
/// Keeps **two** BGRA textures the size of the remote screen, alternating. Each update is written to the texture the GPU is **not** reading,
/// and that texture then becomes the one to draw. Overwriting the texture the GPU is reading (the old single-texture approach) can tear: Metal
/// does not synchronize `replace(region:)` with a draw command in flight. Each texture remembers the regions it is missing (changed while we wrote to the
/// other texture), so each time only what is needed is uploaded (`replace(region:)` reads straight from framebuffer memory with no extra copy) and
/// there is no need to retain the frame (retaining it would force the session to copy the whole buffer on the next write).
@MainActor
public final class FramebufferSurface: SurfaceTexture {
    public let device: MTLDevice
    private var textures: [MTLTexture] = []
    /// Texture currently used for drawing (the newest).
    private var current = 0
    /// Regions each texture is still missing compared to the framebuffer; `nil` means missing entirely.
    private var missing: [[PixelRect]?] = [nil, nil]
    /// Number of draw commands pending on the GPU for each texture, along with the "generation" of the texture pair (changes on recreation, so an old command finishing does not
    /// wrongly decrement the new pair). Metal's completion handler runs on another thread, hence the lock.
    private let inFlight = OSAllocatedUnfairLock(initialState: (generation: 0, counts: [0, 0]))
    /// Too many regions are treated as missing entirely (uploading the whole screen once is cheaper than managing hundreds of small regions).
    static let maxTrackedRects = 32

    public private(set) var size: (width: Int, height: Int) = (0, 0)
    public var pixelLayout: SurfacePixelLayout { .bgra }

    public init(device: MTLDevice) {
        self.device = device
    }

    /// Pushes the changed regions of `framebuffer` to the texture. `dirty == nil` means push everything.
    /// The texture is recreated (and fully uploaded) when the remote screen size changes.
    public func upload(_ framebuffer: Framebuffer, dirty: [PixelRect]? = nil) {
        if textures.isEmpty || size != (framebuffer.width, framebuffer.height) {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm, width: framebuffer.width, height: framebuffer.height, mipmapped: false
            )
            descriptor.usage = .shaderRead
            descriptor.storageMode = .shared
            guard let first = device.makeTexture(descriptor: descriptor), let second = device.makeTexture(descriptor: descriptor) else { return }
            textures = [first, second]
            missing = [nil, nil]
            current = 0
            size = (framebuffer.width, framebuffer.height)
            inFlight.withLock { $0 = (generation: $0.generation + 1, counts: [0, 0]) }
        }

        // Write to the texture the GPU is not reading; prefer the other one (the current texture was just drawn and is likely busy).
        let counts = inFlight.withLock { $0.counts }
        let other = 1 - current
        let target = counts[other] == 0 ? other : (counts[current] == 0 ? current : other)

        // Regions to write: whatever this texture is still missing plus the region that just changed. The framebuffer is always complete, so once written the texture is correct.
        let regions: [PixelRect]
        if let lacking = missing[target], let dirty {
            regions = lacking + dirty
        } else {
            regions = [framebuffer.bounds]
        }
        let stride = framebuffer.width * Framebuffer.bytesPerPixel
        let texture = textures[target]
        framebuffer.pixels.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            for rect in regions where framebuffer.contains(rect) {
                // Point straight at the region's first pixel in framebuffer memory; `bytesPerRow` is the stride of a whole row.
                let origin = base + rect.y * stride + rect.x * Framebuffer.bytesPerPixel
                texture.replace(
                    region: MTLRegionMake2D(rect.x, rect.y, rect.width, rect.height),
                    mipmapLevel: 0, withBytes: origin, bytesPerRow: stride
                )
            }
        }
        missing[target] = []
        // The other texture is now additionally missing the region that just changed.
        let rest = 1 - target
        if let lacking = missing[rest], let dirty, lacking.count + dirty.count <= Self.maxTrackedRects {
            missing[rest] = lacking + dirty
        } else {
            missing[rest] = nil
        }
        current = target
    }

    /// Number of draw commands pending on the GPU for the two textures (for tests).
    var inFlightCounts: [Int] { inFlight.withLock { $0.counts } }

    public func beginDraw(in commandBuffer: MTLCommandBuffer) -> SurfaceFrame? {
        guard textures.indices.contains(current) else { return nil } // no data yet
        let texture = textures[current]
        // Mark this texture as being read by the GPU until the draw finishes, so the next upload does not overwrite it.
        let index = current
        let generation = inFlight.withLock { state -> Int in
            state.counts[index] += 1
            return state.generation
        }
        commandBuffer.addCompletedHandler { [inFlight] _ in
            inFlight.withLock { state in
                if state.generation == generation { state.counts[index] -= 1 }
            }
        }
        return SurfaceFrame(primary: texture)
    }
}
