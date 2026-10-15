import CoreGraphics
import Foundation
import Metal
import os
import RFBKit

/// Vẽ `Framebuffer` của Mac lên GPU bằng Metal.
///
/// Giữ **hai** texture BGRA cùng cỡ màn hình từ xa, luân phiên. Mỗi cập nhật được ghi vào texture mà GPU **không** đang đọc,
/// rồi texture đó thành texture để vẽ. Ghi đè đúng texture GPU đang đọc (cách cũ, một texture) có thể làm xé hình: Metal
/// không đồng bộ `replace(region:)` với lệnh vẽ đang chạy. Mỗi texture nhớ các vùng nó còn thiếu (đã đổi lúc ta ghi vào texture
/// kia), nên mỗi lần chỉ tải phần cần thiết (`replace(region:)` đọc thẳng từ bộ nhớ framebuffer, không sao chép thêm) và
/// không phải giữ lại khung hình (giữ thì session phải sao chép cả bộ đệm ở lần ghi sau).
/// Mỗi khung hình vẽ một hình chữ nhật có texture, vị trí do `ViewportGeometry` quyết định.
///
/// Không phụ thuộc UIKit, nên chạy và test được trên macOS bằng cách vẽ ra texture rồi đọc ngược.
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
    /// Texture đang dùng để vẽ (mới nhất).
    private var current = 0
    /// Vùng mỗi texture còn thiếu so với framebuffer; `nil` là thiếu toàn bộ.
    private var missing: [[PixelRect]?] = [nil, nil]
    /// Số lệnh vẽ đang chờ GPU cho từng texture, cùng "thế hệ" của cặp texture (đổi khi tạo lại, để lệnh cũ hoàn tất không
    /// trừ nhầm vào cặp mới). Trình xử lý hoàn tất của Metal chạy ở luồng khác nên cần khóa.
    private let inFlight = OSAllocatedUnfairLock(initialState: (generation: 0, counts: [0, 0]))
    /// Quá nhiêu vùng thì coi như thiếu toàn bộ (tải cả màn hình một lần rẻ hơn quản lý hàng trăm vùng nhỏ).
    static let maxTrackedRects = 32
    private var cursorTexture: MTLTexture?
    private var cursorImage: CursorImage?

    /// Cỡ texture hiện tại, `(0, 0)` nếu chưa có dữ liệu.
    public private(set) var textureSize: (width: Int, height: Int) = (0, 0)

    /// Hình chữ nhật có texture, bốn đỉnh theo thứ tự triangle strip. `rect` là `(trái, dưới, phải, trên)` trong
    /// toạ độ chuẩn hóa. uv.y = 0 ở mép TRÊN của ảnh, khớp với hàng đầu tiên của framebuffer.
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

    // Con trỏ: pixel trong suốt là (0, 0, 0, 0) và pixel đục có alpha 255, tức đã nhân sẵn alpha,
    // nên lấy mẫu tuyến tính không sinh viền đen và hòa trộn dùng (one, oneMinusSourceAlpha).
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

    // MARK: - Đưa dữ liệu lên GPU

    /// Đẩy các vùng thay đổi của `framebuffer` lên texture. `dirty == nil` nghĩa là đẩy toàn bộ.
    /// Texture được tạo lại (và đẩy toàn bộ) khi cỡ màn hình từ xa đổi.
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

        // Ghi vào texture GPU không đang đọc; ưu tiên texture kia (texture hiện tại vừa được vẽ, rất có thể đang bận).
        let counts = inFlight.withLock { $0.counts }
        let other = 1 - current
        let target = counts[other] == 0 ? other : (counts[current] == 0 ? current : other)

        // Vùng cần ghi: những gì texture này còn thiếu cộng vùng vừa đổi. Framebuffer luôn đầy đủ nên ghi xong là texture đúng.
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
                // Trỏ thẳng tới pixel đầu của vùng trong bộ nhớ framebuffer; `bytesPerRow` là bước nhảy cả hàng.
                let origin = base + rect.y * stride + rect.x * Framebuffer.bytesPerPixel
                texture.replace(
                    region: MTLRegionMake2D(rect.x, rect.y, rect.width, rect.height),
                    mipmapLevel: 0, withBytes: origin, bytesPerRow: stride
                )
            }
        }
        missing[target] = []
        // Texture còn lại giờ thiếu thêm vùng vừa đổi.
        let rest = 1 - target
        if let lacking = missing[rest], let dirty, lacking.count + dirty.count <= Self.maxTrackedRects {
            missing[rest] = lacking + dirty
        } else {
            missing[rest] = nil
        }
        current = target
    }

    /// Số lệnh vẽ đang chờ GPU cho hai texture (cho test).
    var inFlightCounts: [Int] { inFlight.withLock { $0.counts } }

    /// Đặt hình con trỏ. `nil` hoặc hình rỗng (server ẩn con trỏ) thì không vẽ con trỏ.
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

    // MARK: - Vẽ

    /// Ghi lệnh vẽ vào `commandBuffer` với pass cho trước. Người gọi tự present và commit.
    /// - Parameters:
    ///   - deviceScale: số pixel thiết bị trên mỗi point (`UIScreen.scale`), để chọn bộ lấy mẫu.
    ///   - pointer: pixel Mac nơi con trỏ đang đứng. `nil` thì không vẽ con trỏ (chưa biết nó ở đâu).
    public func encode(
        into commandBuffer: MTLCommandBuffer,
        pass: MTLRenderPassDescriptor,
        geometry: ViewportGeometry,
        deviceScale: Double = 1,
        pointer: (x: Int, y: Int)? = nil
    ) {
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        defer { encoder.endEncoding() }
        guard textures.indices.contains(current) else { return } // chưa có dữ liệu: chỉ xóa nền
        let texture = textures[current]
        // Đánh dấu texture này đang được GPU đọc cho tới khi lệnh vẽ xong, để lần tải sau không ghi đè lên nó.
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

        // Phóng to (mỗi pixel Mac phủ từ 1 pixel thiết bị trở lên) thì lấy pixel gần nhất cho sắc nét.
        // Thu nhỏ thì lấy nội suy để bớt răng cưa.
        let magnifying = geometry.scale * deviceScale >= 1
        var rect = geometry.normalizedDeviceRect
        encoder.setRenderPipelineState(pipelineState)
        encoder.setVertexBytes(&rect, length: MemoryLayout<SIMD4<Float>>.size, index: 0)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentSamplerState(magnifying ? nearestSampler : linearSampler, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)

        // Con trỏ nằm trên cùng. Server tách con trỏ khỏi framebuffer nên không vẽ thì người dùng không thấy nó.
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

    /// Vẽ ra một texture bất kỳ rồi chờ GPU xong. Dùng cho test và chụp ảnh, không dùng trong vòng vẽ của view.
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

    /// Hàng đợi lệnh, để `MTKView` dùng chung.
    public func makeCommandBuffer() -> MTLCommandBuffer? {
        commandQueue.makeCommandBuffer()
    }
}
