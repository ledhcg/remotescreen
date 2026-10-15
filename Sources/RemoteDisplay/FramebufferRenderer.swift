import CoreGraphics
import Foundation
import Metal
import os
import RFBKit

/// Draws the Mac's `Framebuffer` on the GPU using Metal.
///
/// Keeps **two** BGRA textures the size of the remote screen, alternating. Each update is written to the texture the GPU is **not** reading,
/// and that texture then becomes the one to draw. Overwriting the texture the GPU is reading (the old single-texture approach) can tear: Metal
/// does not synchronize `replace(region:)` with a draw command in flight. Each texture remembers the regions it is missing (changed while we wrote to the
/// other texture), so each time only what is needed is uploaded (`replace(region:)` reads straight from framebuffer memory with no extra copy) and
/// there is no need to retain the frame (retaining it would force the session to copy the whole buffer on the next write).
/// Each frame draws one textured rectangle, whose position is decided by `ViewportGeometry`.
///
/// No UIKit dependency, so it runs and can be tested on macOS by drawing to a texture and reading it back.
@MainActor
public final class FramebufferRenderer {
    public enum RendererError: Error, Equatable {
        case noCommandQueue
        case shader(String)
        case pipeline(String)
    }

    public let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipelineState: MTLRenderPipelineState
    private let cursorPipelineState: MTLRenderPipelineState
    private let nearestSampler: MTLSamplerState
    private let linearSampler: MTLSamplerState
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
    private var cursorTexture: MTLTexture?
    private var cursorImage: CursorImage?

    /// Current texture size, `(0, 0)` if there is no data yet.
    public private(set) var textureSize: (width: Int, height: Int) = (0, 0)

    /// Textured rectangle, four vertices in triangle strip order. `rect` is `(left, bottom, right, top)` in
    /// normalized coordinates. uv.y = 0 is at the TOP edge of the image, matching the first row of the framebuffer.
    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct VertexOut {
        float4 position [[position]];
        float2 uv;
    };

    vertex VertexOut screenVertex(uint vertexID [[vertex_id]], constant float4 &rect [[buffer(0)]]) {
        float2 corners[4] = { float2(0, 0), float2(1, 0), float2(0, 1), float2(1, 1) };
        float2 uv = corners[vertexID];
        VertexOut out;
        out.position = float4(mix(rect.x, rect.z, uv.x), mix(rect.w, rect.y, uv.y), 0, 1);
        out.uv = uv;
        return out;
    }

    fragment float4 screenFragment(VertexOut in [[stage_in]],
                                   texture2d<float> screen [[texture(0)]],
                                   sampler screenSampler [[sampler(0)]]) {
        return float4(screen.sample(screenSampler, in.uv).rgb, 1.0);
    }

    // Cursor: transparent pixels are (0, 0, 0, 0) and opaque pixels have alpha 255, i.e. alpha is premultiplied,
    // so linear sampling produces no black fringe and blending uses (one, oneMinusSourceAlpha).
    fragment float4 cursorFragment(VertexOut in [[stage_in]],
                                   texture2d<float> cursor [[texture(0)]],
                                   sampler cursorSampler [[sampler(0)]]) {
        return cursor.sample(cursorSampler, in.uv);
    }
    """

    public init(device: MTLDevice, colorPixelFormat: MTLPixelFormat = .bgra8Unorm) throws {
        self.device = device
        guard let queue = device.makeCommandQueue() else { throw RendererError.noCommandQueue }
        commandQueue = queue

        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: Self.shaderSource, options: nil)
        } catch {
            throw RendererError.shader("\(error)")
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "screenVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "screenFragment")
        descriptor.colorAttachments[0].pixelFormat = colorPixelFormat
        do {
            pipelineState = try device.makeRenderPipelineState(descriptor: descriptor)

            let cursorDescriptor = MTLRenderPipelineDescriptor()
            cursorDescriptor.vertexFunction = library.makeFunction(name: "screenVertex")
            cursorDescriptor.fragmentFunction = library.makeFunction(name: "cursorFragment")
            let attachment = cursorDescriptor.colorAttachments[0]!
            attachment.pixelFormat = colorPixelFormat
            attachment.isBlendingEnabled = true
            attachment.sourceRGBBlendFactor = .one
            attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
            attachment.sourceAlphaBlendFactor = .one
            attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            cursorPipelineState = try device.makeRenderPipelineState(descriptor: cursorDescriptor)
        } catch {
            throw RendererError.pipeline("\(error)")
        }

        func sampler(_ filter: MTLSamplerMinMagFilter) throws -> MTLSamplerState {
            let descriptor = MTLSamplerDescriptor()
            descriptor.minFilter = filter
            descriptor.magFilter = filter
            descriptor.sAddressMode = .clampToEdge
            descriptor.tAddressMode = .clampToEdge
            guard let state = device.makeSamplerState(descriptor: descriptor) else { throw RendererError.pipeline("sampler") }
            return state
        }
        nearestSampler = try sampler(.nearest)
        linearSampler = try sampler(.linear)
    }

    // MARK: - Uploading data to the GPU

    /// Pushes the changed regions of `framebuffer` to the texture. `dirty == nil` means push everything.
    /// The texture is recreated (and fully uploaded) when the remote screen size changes.
    public func upload(_ framebuffer: Framebuffer, dirty: [PixelRect]? = nil) {
        if textures.isEmpty || textureSize != (framebuffer.width, framebuffer.height) {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm, width: framebuffer.width, height: framebuffer.height, mipmapped: false
            )
            descriptor.usage = .shaderRead
            descriptor.storageMode = .shared
            guard let first = device.makeTexture(descriptor: descriptor), let second = device.makeTexture(descriptor: descriptor) else { return }
            textures = [first, second]
            missing = [nil, nil]
            current = 0
            textureSize = (framebuffer.width, framebuffer.height)
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

    /// Sets the cursor image. `nil` or an empty image (the server hides the cursor) draws no cursor.
    public func setCursor(_ cursor: CursorImage?) {
        guard let cursor, !cursor.isEmpty else {
            cursorImage = nil
            cursorTexture = nil
            return
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: cursor.width, height: cursor.height, mipmapped: false
        )
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        guard let newTexture = device.makeTexture(descriptor: descriptor) else {
            cursorImage = nil
            cursorTexture = nil
            return
        }
        cursor.bgra.withUnsafeBytes { bytes in
            newTexture.replace(
                region: MTLRegionMake2D(0, 0, cursor.width, cursor.height),
                mipmapLevel: 0, withBytes: bytes.baseAddress!, bytesPerRow: cursor.width * 4
            )
        }
        cursorImage = cursor
        cursorTexture = newTexture
    }

    // MARK: - Drawing

    /// Encodes the draw commands into `commandBuffer` with the given pass. The caller presents and commits.
    /// - Parameters:
    /// - deviceScale: device pixels per point (`UIScreen.scale`), used to choose the sampler.
    /// - pointer: Mac pixel where the pointer is. `nil` draws no cursor (its position is not yet known).
    public func encode(
        into commandBuffer: MTLCommandBuffer,
        pass: MTLRenderPassDescriptor,
        geometry: ViewportGeometry,
        deviceScale: Double = 1,
        pointer: (x: Int, y: Int)? = nil
    ) {
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        defer { encoder.endEncoding() }
        guard textures.indices.contains(current) else { return } // no data yet: only clear the background
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

        // Zoomed in (each Mac pixel covers one device pixel or more): use nearest-pixel sampling for sharpness.
        // Zoomed out: use interpolation to reduce aliasing.
        let magnifying = geometry.scale * deviceScale >= 1
        var rect = geometry.normalizedDeviceRect
        encoder.setRenderPipelineState(pipelineState)
        encoder.setVertexBytes(&rect, length: MemoryLayout<SIMD4<Float>>.size, index: 0)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentSamplerState(magnifying ? nearestSampler : linearSampler, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)

        // The cursor goes on top. The server separates the cursor from the framebuffer, so if we did not draw it the user would not see it.
        if let cursorTexture, let cursorImage, let pointer {
            let placed = CursorPlacement.viewRect(for: cursorImage, pointer: pointer, geometry: geometry)
            var cursorRect = CursorPlacement.normalizedDeviceRect(viewRect: placed, viewSize: geometry.viewSize)
            encoder.setRenderPipelineState(cursorPipelineState)
            encoder.setVertexBytes(&cursorRect, length: MemoryLayout<SIMD4<Float>>.size, index: 0)
            encoder.setFragmentTexture(cursorTexture, index: 0)
            encoder.setFragmentSamplerState(linearSampler, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
    }

    /// Draws to an arbitrary texture and waits for the GPU to finish. Used for tests and screenshots, not in the view's draw loop.
    public func render(
        to target: MTLTexture,
        geometry: ViewportGeometry,
        deviceScale: Double = 1,
        pointer: (x: Int, y: Int)? = nil,
        clearColor: MTLClearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
    ) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = clearColor
        pass.colorAttachments[0].storeAction = .store
        guard let buffer = commandQueue.makeCommandBuffer() else { return }
        encode(into: buffer, pass: pass, geometry: geometry, deviceScale: deviceScale, pointer: pointer)
        buffer.commit()
        buffer.waitUntilCompleted()
    }

    /// Command queue, shared with `MTKView`.
    public func makeCommandBuffer() -> MTLCommandBuffer? {
        commandQueue.makeCommandBuffer()
    }
}
