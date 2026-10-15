import CoreGraphics
import Foundation
import Metal
import RFBKit
import Testing
@testable import RemoteDisplay

/// Chạy shader thật trên GPU rồi đọc ngược pixel, để biết con trỏ thực sự nằm đúng chỗ, đúng màu, trong suốt đúng chỗ.
///
/// Số liệu chọn để tâm mỗi ô con trỏ trùng tâm pixel đích (con trỏ 5×5 hiển thị 4 point mỗi pixel), nên so sánh
/// chính xác từng giá trị mà không bị nội suy tuyến tính làm nhòe.
@MainActor
@Suite("Vẽ con trỏ (GPU thật)", .enabled(if: MTLCreateSystemDefaultDevice() != nil))
struct CursorRenderingTests {
    typealias RGB = (r: UInt8, g: UInt8, b: UInt8)
    private let screenColour: RGB = (20, 60, 200)
    private let red: RGB = (255, 0, 0)

    private func makeRenderer() throws -> FramebufferRenderer {
        try FramebufferRenderer(device: #require(MTLCreateSystemDefaultDevice()))
    }

    private func makeTarget(_ renderer: FramebufferRenderer, size: Int) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: size, height: size, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        return try #require(renderer.device.makeTexture(descriptor: descriptor))
    }

    private func pixel(_ texture: MTLTexture, x: Int, y: Int) -> RGB {
        var bytes = [UInt8](repeating: 0, count: 4)
        texture.getBytes(&bytes, bytesPerRow: 4, from: MTLRegionMake2D(x, y, 1, 1), mipmapLevel: 0)
        return (bytes[2], bytes[1], bytes[0])
    }

    private func solidScreen(width: Int, height: Int) throws -> Framebuffer {
        var screen = try Framebuffer(width: width, height: height)
        let bgra = [UInt8](repeating: 0, count: 0) + (0..<(width * height)).flatMap { _ in [screenColour.b, screenColour.g, screenColour.r, 0] }
        try screen.write(screen.bounds, bgra: bgra)
        return screen
    }

    /// 5×5 đỏ đục, riêng ô (4, 4) trong suốt, điểm nóng ở ô giữa (2, 2).
    private func makeCursor() throws -> CursorImage {
        var bgra: [UInt8] = []
        for y in 0..<5 {
            for x in 0..<5 {
                bgra += (x == 4 && y == 4) ? [0, 0, 0, 0] : [0, 0, 255, 255] // B, G, R, A
            }
        }
        return try #require(CursorImage(width: 5, height: 5, hotspotX: 2, hotspotY: 2, bgra: bgra))
    }

    private func equal(_ a: RGB, _ b: RGB) -> Bool { a.r == b.r && a.g == b.g && a.b == b.b }

    @Test func cursorIsDrawnAroundItsHotspotWithTransparencyRespected() throws {
        let renderer = try makeRenderer()
        renderer.upload(try solidScreen(width: 100, height: 100))
        renderer.setCursor(try makeCursor())
        let target = try makeTarget(renderer, size: 100)
        let geometry = ViewportGeometry(remoteSize: CGSize(width: 100, height: 100), viewSize: CGSize(width: 100, height: 100))

        renderer.render(to: target, geometry: geometry, pointer: (50, 50))

        // Con trỏ phủ khung nhìn từ 42,5 tới 62,5 theo cả hai trục, mỗi ô 4 point.
        #expect(equal(pixel(target, x: 52, y: 52), red), "ô giữa, ngay điểm nóng")
        #expect(equal(pixel(target, x: 44, y: 44), red), "ô góc trên trái")
        #expect(equal(pixel(target, x: 60, y: 44), red), "ô góc trên phải")
        #expect(equal(pixel(target, x: 44, y: 60), red), "ô góc dưới trái")
        #expect(equal(pixel(target, x: 60, y: 60), screenColour), "ô trong suốt phải lộ nền màn hình, không đen")
        #expect(equal(pixel(target, x: 30, y: 30), screenColour), "ngoài con trỏ")
        #expect(equal(pixel(target, x: 80, y: 80), screenColour), "ngoài con trỏ")
        #expect(equal(pixel(target, x: 41, y: 52), screenColour), "ngay trái mép con trỏ")
        #expect(equal(pixel(target, x: 63, y: 52), screenColour), "ngay phải mép con trỏ")
    }

    @Test func noPointerMeansNoCursor() throws {
        let renderer = try makeRenderer()
        renderer.upload(try solidScreen(width: 100, height: 100))
        renderer.setCursor(try makeCursor())
        let target = try makeTarget(renderer, size: 100)
        let geometry = ViewportGeometry(remoteSize: CGSize(width: 100, height: 100), viewSize: CGSize(width: 100, height: 100))

        renderer.render(to: target, geometry: geometry, pointer: nil)
        #expect(equal(pixel(target, x: 52, y: 52), screenColour))
    }

    @Test func emptyOrMissingCursorIsHidden() throws {
        let renderer = try makeRenderer()
        renderer.upload(try solidScreen(width: 100, height: 100))
        let target = try makeTarget(renderer, size: 100)
        let geometry = ViewportGeometry(remoteSize: CGSize(width: 100, height: 100), viewSize: CGSize(width: 100, height: 100))

        renderer.setCursor(try makeCursor())
        renderer.setCursor(nil) // server ẩn con trỏ
        renderer.render(to: target, geometry: geometry, pointer: (50, 50))
        #expect(equal(pixel(target, x: 52, y: 52), screenColour))

        renderer.setCursor(try makeCursor())
        let hidden = try #require(CursorImage(width: 0, height: 0, hotspotX: 0, hotspotY: 0, bgra: []))
        renderer.setCursor(hidden)
        renderer.render(to: target, geometry: geometry, pointer: (50, 50))
        #expect(equal(pixel(target, x: 52, y: 52), screenColour))
    }

    @Test func cursorStaysVisibleWhenTheWholeMacScreenIsShrunk() throws {
        let renderer = try makeRenderer()
        renderer.upload(try solidScreen(width: 1000, height: 1000))
        renderer.setCursor(try makeCursor())
        let target = try makeTarget(renderer, size: 100)
        // Mac 1000×1000 vào khung nhìn 100×100: 0,1 point/pixel. Vẽ đúng tỉ lệ thì con trỏ 5 pixel chỉ rộng nửa point.
        let geometry = ViewportGeometry(remoteSize: CGSize(width: 1000, height: 1000), viewSize: CGSize(width: 100, height: 100))

        renderer.render(to: target, geometry: geometry, pointer: (500, 500))
        #expect(equal(pixel(target, x: 52, y: 52), red))
        #expect(equal(pixel(target, x: 20, y: 20), screenColour))
    }

    @Test func newCursorShapeReplacesTheOldOne() throws {
        let renderer = try makeRenderer()
        renderer.upload(try solidScreen(width: 100, height: 100))
        let target = try makeTarget(renderer, size: 100)
        let geometry = ViewportGeometry(remoteSize: CGSize(width: 100, height: 100), viewSize: CGSize(width: 100, height: 100))

        renderer.setCursor(try makeCursor())
        let green = try #require(CursorImage(width: 5, height: 5, hotspotX: 2, hotspotY: 2, bgra: [UInt8](repeating: 0, count: 100).enumerated().map { $0.offset % 4 == 1 || $0.offset % 4 == 3 ? 255 : 0 }))
        renderer.setCursor(green)
        renderer.render(to: target, geometry: geometry, pointer: (50, 50))
        #expect(equal(pixel(target, x: 52, y: 52), (0, 255, 0)))
        #expect(equal(pixel(target, x: 60, y: 60), (0, 255, 0)), "hình mới đục toàn phần, ô góc dưới phải cũng xanh")
    }
}
