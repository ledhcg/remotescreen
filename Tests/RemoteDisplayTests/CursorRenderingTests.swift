import CoreGraphics
import Foundation
import Metal
import RFBKit
import Testing
@testable import RemoteDisplay

/// Runs the real shader on the GPU and reads the pixels back, to know the cursor really lands in the right place, with the right color, transparent where it should be.
///
/// The numbers are chosen so each cursor cell's center coincides with the destination pixel's center (a 5×5 cursor shown at 4 points per pixel), so values are compared
/// exactly without linear interpolation blurring them.
@MainActor
@Suite("Cursor drawing (real GPU)", .enabled(if: gpuTestsAvailable))
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

    /// 5×5 opaque red, with cell (4, 4) alone transparent, hotspot at the middle cell (2, 2).
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

        // The cursor covers the viewport from 42.5 to 62.5 on both axes, 4 points per cell.
        #expect(equal(pixel(target, x: 52, y: 52), red), "middle cell, right at the hotspot")
        #expect(equal(pixel(target, x: 44, y: 44), red), "top left corner cell")
        #expect(equal(pixel(target, x: 60, y: 44), red), "top right corner cell")
        #expect(equal(pixel(target, x: 44, y: 60), red), "bottom left corner cell")
        #expect(equal(pixel(target, x: 60, y: 60), screenColour), "the transparent cell must reveal the screen background, not black")
        #expect(equal(pixel(target, x: 30, y: 30), screenColour), "outside the cursor")
        #expect(equal(pixel(target, x: 80, y: 80), screenColour), "outside the cursor")
        #expect(equal(pixel(target, x: 41, y: 52), screenColour), "just left of the cursor's edge")
        #expect(equal(pixel(target, x: 63, y: 52), screenColour), "just right of the cursor's edge")
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
        renderer.setCursor(nil) // the server hides the cursor
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
        // A 1000×1000 Mac in a 100×100 viewport: 0.1 point/pixel. Drawn to true scale, a 5-pixel cursor would be only half a point wide.
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
        #expect(equal(pixel(target, x: 60, y: 60), (0, 255, 0)), "the new image is fully opaque, so the bottom right cell is green too")
    }
}
