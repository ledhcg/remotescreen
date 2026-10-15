import CoreGraphics
import Foundation
import Metal
import RFBKit

/// Draws surfaces with Metal: a main surface (optionally a sub-rectangle of it, `uvRect`), then child surfaces at offsets relative
/// to the main one, then the cursor. Where things land is decided by `ViewportGeometry`.
///
/// No UIKit dependency, so it runs and can be tested on macOS by drawing to a texture and reading it back.
@MainActor
public final class SurfaceCompositor {
    public typealias RendererError = SurfaceError

    public let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let bgraPipeline: MTLRenderPipelineState
    private let videoPipeline: MTLRenderPipelineState
    private let cursorPipeline: MTLRenderPipelineState
    private let nearestSampler: MTLSamplerState
    private let linearSampler: MTLSamplerState
    private var cursorTexture: MTLTexture?
    private var cursorImage: CursorImage?

    /// Textured rectangle, four vertices in triangle strip order. `rect` is `(left, bottom, right, top)` in
    /// normalized device coordinates; `uvRect` is `(u0, v0, u1, v1)` of the part of the texture to show. v = 0 is at the TOP edge of the
    /// image, matching the first row of the framebuffer.
    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct VertexOut {
        float4 position [[position]];
        float2 uv;
    };

    vertex VertexOut screenVertex(uint vertexID [[vertex_id]],
                                  constant float4 &rect [[buffer(0)]],
                                  constant float4 &uvRect [[buffer(1)]]) {
        float2 corners[4] = { float2(0, 0), float2(1, 0), float2(0, 1), float2(1, 1) };
        float2 corner = corners[vertexID];
        VertexOut out;
        out.position = float4(mix(rect.x, rect.z, corner.x), mix(rect.w, rect.y, corner.y), 0, 1);
        out.uv = float2(mix(uvRect.x, uvRect.z, corner.x), mix(uvRect.y, uvRect.w, corner.y));
        return out;
    }

    fragment float4 screenFragment(VertexOut in [[stage_in]],
                                   texture2d<float> screen [[texture(0)]],
                                   sampler screenSampler [[sampler(0)]]) {
        return float4(screen.sample(screenSampler, in.uv).rgb, 1.0);
    }

    // Video range YCbCr 4:2:0 to RGB, BT.709. `range` is (luma offset, luma scale, chroma offset, chroma scale) in sampled units,
    // so one shader serves 8-bit and 10-bit (16-bit textures with the code in the top bits).
    fragment float4 videoFragment(VertexOut in [[stage_in]],
                                  texture2d<float> luma [[texture(0)]],
                                  texture2d<float> chroma [[texture(1)]],
                                  sampler videoSampler [[sampler(0)]],
                                  constant float4 &range [[buffer(0)]]) {
        float y = (luma.sample(videoSampler, in.uv).r - range.x) * range.y;
        float2 c = (chroma.sample(videoSampler, in.uv).rg - range.z) * range.w;
        float3 rgb = float3(y + 1.5748 * c.y, y - 0.187324 * c.x - 0.468124 * c.y, y + 1.8556 * c.x);
        return float4(saturate(rgb), 1.0);
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
        guard let queue = device.makeCommandQueue() else { throw SurfaceError.noCommandQueue }
        commandQueue = queue

        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: Self.shaderSource, options: nil)
        } catch {
            throw SurfaceError.shader("\(error)")
        }

        func pipeline(fragment: String, blending: Bool) throws -> MTLRenderPipelineState {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "screenVertex")
            descriptor.fragmentFunction = library.makeFunction(name: fragment)
            let attachment = descriptor.colorAttachments[0]!
            attachment.pixelFormat = colorPixelFormat
            if blending {
                attachment.isBlendingEnabled = true
                attachment.sourceRGBBlendFactor = .one
                attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
                attachment.sourceAlphaBlendFactor = .one
                attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            }
            return try device.makeRenderPipelineState(descriptor: descriptor)
        }
        do {
            bgraPipeline = try pipeline(fragment: "screenFragment", blending: false)
            videoPipeline = try pipeline(fragment: "videoFragment", blending: false)
            cursorPipeline = try pipeline(fragment: "cursorFragment", blending: true)
        } catch {
            throw SurfaceError.pipeline("\(error)")
        }

        func sampler(_ filter: MTLSamplerMinMagFilter) throws -> MTLSamplerState {
            let descriptor = MTLSamplerDescriptor()
            descriptor.minFilter = filter
            descriptor.magFilter = filter
            descriptor.sAddressMode = .clampToEdge
            descriptor.tAddressMode = .clampToEdge
            guard let state = device.makeSamplerState(descriptor: descriptor) else { throw SurfaceError.pipeline("sampler") }
            return state
        }
        nearestSampler = try sampler(.nearest)
        linearSampler = try sampler(.linear)
    }

    // MARK: - Cursor

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

    /// Conversion constants for video range YCbCr: `(luma offset, luma scale, chroma offset, chroma scale)` in sampled (0...1) units.
    /// 10-bit data lives in the top bits of 16-bit texels, so a code `v` samples as `v * 64 / 65535`.
    static func videoRange(bitDepth: Int) -> SIMD4<Float> {
        let unit = bitDepth >= 10 ? 64.0 / 65535.0 : 1.0 / 255.0
        let shift = Double(1 << max(bitDepth - 8, 0))
        return SIMD4(
            Float(16 * shift * unit), Float(1 / (219 * shift * unit)),
            Float(128 * shift * unit), Float(1 / (224 * shift * unit))
        )
    }

    /// Encodes the draw commands into `commandBuffer` with the given pass. The caller presents and commits.
    /// - Parameters:
    ///   - main: surface drawn under everything else. `nil` only clears the background.
    ///   - uvRect: part of `main` to show, normalized. `nil` takes it from the geometry's `sourceRect`.
    ///   - children: surfaces drawn over `main` in order, positioned in `main`'s pixels.
    ///   - deviceScale: device pixels per point (`UIScreen.scale`), used to choose the sampler.
    ///   - pointer: Mac pixel where the pointer is. `nil` draws no cursor (its position is not yet known).
    public func encode(
        into commandBuffer: MTLCommandBuffer,
        pass: MTLRenderPassDescriptor,
        main: (any SurfaceTexture)?,
        uvRect: CGRect? = nil,
        children: [ChildSurface] = [],
        geometry: ViewportGeometry,
        deviceScale: Double = 1,
        pointer: (x: Int, y: Int)? = nil
    ) {
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        defer { encoder.endEncoding() }

        // Zoomed in (each Mac pixel covers one device pixel or more): use nearest-pixel sampling for sharpness.
        // Zoomed out: use interpolation to reduce aliasing.
        let magnifying = geometry.scale * deviceScale >= 1
        let sampler = magnifying ? nearestSampler : linearSampler

        var mainDrawn = false
        if let main {
            let uv: SIMD4<Float>
            if let uvRect {
                uv = SIMD4(Float(uvRect.minX), Float(uvRect.minY), Float(uvRect.maxX), Float(uvRect.maxY))
            } else {
                uv = geometry.sourceUVRect
            }
            mainDrawn = draw(main, rect: geometry.normalizedDeviceRect, uv: uv, sampler: sampler, encoder: encoder, commandBuffer: commandBuffer)
        }

        for child in children {
            let size = child.surface.size
            guard size.width > 0, size.height > 0 else { continue }
            let uv = child.uvRect ?? CGRect(x: 0, y: 0, width: 1, height: 1)
            let origin = geometry.viewPoint(forRemote: child.offset)
            let viewRect = CGRect(
                x: origin.x, y: origin.y,
                width: Double(size.width) * uv.width * geometry.scale, height: Double(size.height) * uv.height * geometry.scale
            )
            draw(
                child.surface,
                rect: CursorPlacement.normalizedDeviceRect(viewRect: viewRect, viewSize: geometry.viewSize),
                uv: SIMD4(Float(uv.minX), Float(uv.minY), Float(uv.maxX), Float(uv.maxY)),
                sampler: sampler, encoder: encoder, commandBuffer: commandBuffer
            )
        }

        // The cursor goes on top. The server separates the cursor from the framebuffer, so if we did not draw it the user would not see it.
        if mainDrawn, let cursorTexture, let cursorImage, let pointer {
            let placed = CursorPlacement.viewRect(for: cursorImage, pointer: pointer, geometry: geometry)
            var cursorRect = CursorPlacement.normalizedDeviceRect(viewRect: placed, viewSize: geometry.viewSize)
            var fullUV = SIMD4<Float>(0, 0, 1, 1)
            encoder.setRenderPipelineState(cursorPipeline)
            encoder.setVertexBytes(&cursorRect, length: MemoryLayout<SIMD4<Float>>.size, index: 0)
            encoder.setVertexBytes(&fullUV, length: MemoryLayout<SIMD4<Float>>.size, index: 1)
            encoder.setFragmentTexture(cursorTexture, index: 0)
            encoder.setFragmentSamplerState(linearSampler, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
    }

    /// Returns `false` when the surface has nothing to draw yet.
    @discardableResult
    private func draw(
        _ surface: any SurfaceTexture, rect: SIMD4<Float>, uv: SIMD4<Float>, sampler: MTLSamplerState,
        encoder: MTLRenderCommandEncoder, commandBuffer: MTLCommandBuffer
    ) -> Bool {
        guard let frame = surface.beginDraw(in: commandBuffer) else { return false } // no data yet
        var rect = rect
        var uv = uv
        switch surface.pixelLayout {
        case .bgra:
            encoder.setRenderPipelineState(bgraPipeline)
        case .ycbcr420(let bitDepth):
            guard let chroma = frame.secondary else { return false }
            var range = Self.videoRange(bitDepth: bitDepth)
            encoder.setRenderPipelineState(videoPipeline)
            encoder.setFragmentTexture(chroma, index: 1)
            encoder.setFragmentBytes(&range, length: MemoryLayout<SIMD4<Float>>.size, index: 0)
        }
        encoder.setVertexBytes(&rect, length: MemoryLayout<SIMD4<Float>>.size, index: 0)
        encoder.setVertexBytes(&uv, length: MemoryLayout<SIMD4<Float>>.size, index: 1)
        encoder.setFragmentTexture(frame.primary, index: 0)
        encoder.setFragmentSamplerState(sampler, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        return true
    }

    /// Draws to an arbitrary texture and waits for the GPU to finish. Used for tests and screenshots, not in the view's draw loop.
    public func render(
        to target: MTLTexture,
        main: (any SurfaceTexture)?,
        uvRect: CGRect? = nil,
        children: [ChildSurface] = [],
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
        encode(into: buffer, pass: pass, main: main, uvRect: uvRect, children: children, geometry: geometry, deviceScale: deviceScale, pointer: pointer)
        buffer.commit()
        buffer.waitUntilCompleted()
    }

    /// Command queue, shared with `MTKView`.
    public func makeCommandBuffer() -> MTLCommandBuffer? {
        commandQueue.makeCommandBuffer()
    }
}
