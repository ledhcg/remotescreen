import CoreGraphics
import Foundation
import Metal
import RFBKit
import Testing
@testable import RemoteDisplay

/// These tests run the real shader on the machine's GPU and read the pixels back to compare with the source data.
@MainActor
@Suite("FramebufferRenderer (real GPU)", .enabled(if: gpuTestsAvailable))
struct FramebufferRendererTests {
    private func makeRenderer() throws -> FramebufferRenderer {
        try FramebufferRenderer(device: #require(MTLCreateSystemDefaultDevice()))
    }

    private func makeTarget(_ renderer: FramebufferRenderer, width: Int, height: Int) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        return try #require(renderer.device.makeTexture(descriptor: descriptor))
    }

    /// Reads back: returns `(r, g, b)` per pixel, the first row being the top row.
    private func readback(_ texture: MTLTexture) -> [[(r: UInt8, g: UInt8, b: UInt8)]] {
        var bytes = [UInt8](repeating: 0, count: texture.width * texture.height * 4)
        texture.getBytes(&bytes, bytesPerRow: texture.width * 4, from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
        return (0..<texture.height).map { y in
            (0..<texture.width).map { x in
                let i = (y * texture.width + x) * 4
                return (bytes[i + 2], bytes[i + 1], bytes[i]) // memory order is B, G, R, A
            }
        }
    }

    /// A 4×2 screen with eight different colors, making wrong positions or wrong channels easy to spot.
    private func makeScreen() throws -> Framebuffer {
        var screen = try Framebuffer(width: 4, height: 2)
        for y in 0..<2 {
            for x in 0..<4 {
                // n from 0 to 7. The factors are chosen so every channel fits in 0...255 (n = 7: B 220, G 180, R 250).
                let n = UInt8(y * 4 + x)
                try screen.write(PixelRect(x: x, y: y, width: 1, height: 1), bgra: [30 * n + 10, 25 * n + 5, 30 * n + 40, 0]) // B, G, R, X
            }
        }
        return screen
    }

    private func isClose(_ a: (r: UInt8, g: UInt8, b: UInt8), _ b: (r: UInt8, g: UInt8, b: UInt8), _ tolerance: Int = 0) -> Bool {
        abs(Int(a.r) - Int(b.r)) <= tolerance && abs(Int(a.g) - Int(b.g)) <= tolerance && abs(Int(a.b) - Int(b.b)) <= tolerance
    }

    @Test func drawsEveryRemotePixelAtTheRightPlaceAndWithTheRightChannels() throws {
        let renderer = try makeRenderer()
        let screen = try makeScreen()
        renderer.upload(screen)
        let target = try makeTarget(renderer, width: 40, height: 20)

        // A 40×20 viewport for a 4×2 screen: scale 10, each Mac pixel is a 10×10 block.
        let geometry = ViewportGeometry(remoteSize: CGSize(width: 4, height: 2), viewSize: CGSize(width: 40, height: 20))
        renderer.render(to: target, geometry: geometry)
        let image = readback(target)

        for y in 0..<2 {
            for x in 0..<4 {
                let expected = try #require(screen.rgb(x: x, y: y))
                #expect(isClose(image[y * 10 + 5][x * 10 + 5], expected), "pixel Mac (\(x), \(y))")
            }
        }
    }

    @Test func letterboxBarsStayBlackAndTheContentIsCentred() throws {
        let renderer = try makeRenderer()
        let screen = try makeScreen()
        renderer.upload(screen)
        let target = try makeTarget(renderer, width: 40, height: 40)
        let geometry = ViewportGeometry(remoteSize: CGSize(width: 4, height: 2), viewSize: CGSize(width: 40, height: 40))
        renderer.render(to: target, geometry: geometry, clearColor: MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1))
        let image = readback(target)

        // The 40×20 content sits at y = 10...30.
        #expect(isClose(image[5][20], (0, 0, 0)), "top border")
        #expect(isClose(image[35][20], (0, 0, 0)), "bottom border")
        #expect(isClose(image[15][5], try #require(screen.rgb(x: 0, y: 0))))
        #expect(isClose(image[25][35], try #require(screen.rgb(x: 3, y: 1))))
    }

    /// The most important invariant: the pixels the GPU draws must match the CPU coordinate conversion that the input side uses.
    /// If they drift apart, touching somewhere would control the wrong place.
    @Test(arguments: [1.0, 2.0, 3.5])
    func gpuOutputAgreesWithTheCPUCoordinateMapping(zoom: Double) throws {
        let renderer = try makeRenderer()
        let screen = try makeScreen()
        renderer.upload(screen)
        let target = try makeTarget(renderer, width: 40, height: 20)
        var geometry = ViewportGeometry(remoteSize: CGSize(width: 4, height: 2), viewSize: CGSize(width: 40, height: 20))
        geometry.zoom(by: zoom, around: CGPoint(x: 13, y: 7))
        geometry.pan(by: CGPoint(x: -3, y: 2))
        renderer.render(to: target, geometry: geometry)
        let image = readback(target)

        var checked = 0
        for y in stride(from: 1, to: 20, by: 2) {
            for x in stride(from: 1, to: 40, by: 2) {
                let point = CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5) // center of the output pixel
                let expected = geometry.remotePixel(forView: point, clamped: false).flatMap { screen.rgb(x: $0.x, y: $0.y) } ?? (0, 0, 0)
                #expect(isClose(image[y][x], expected), "zoom \(zoom), point (\(x), \(y))")
                checked += 1
            }
        }
        #expect(checked == 200)
    }

    @Test func incrementalUploadTouchesOnlyTheDirtyRectangle() throws {
        let renderer = try makeRenderer()
        var screen = try makeScreen()
        renderer.upload(screen)

        try screen.write(PixelRect(x: 2, y: 1, width: 1, height: 1), bgra: [255, 0, 0, 0]) // pure blue
        renderer.upload(screen, dirty: [PixelRect(x: 2, y: 1, width: 1, height: 1)])

        let target = try makeTarget(renderer, width: 40, height: 20)
        renderer.render(to: target, geometry: ViewportGeometry(remoteSize: CGSize(width: 4, height: 2), viewSize: CGSize(width: 40, height: 20)))
        let image = readback(target)

        #expect(isClose(image[15][25], (0, 0, 255)), "pixel that just changed")
        #expect(isClose(image[15][15], try #require(screen.rgb(x: 1, y: 1))), "neighboring pixel unchanged")
        #expect(isClose(image[5][5], try #require(screen.rgb(x: 0, y: 0))))
    }

    @Test func aNewRemoteSizeRecreatesTheTexture() throws {
        let renderer = try makeRenderer()
        renderer.upload(try makeScreen())
        #expect(renderer.textureSize == (4, 2))

        var bigger = try Framebuffer(width: 8, height: 6)
        try bigger.write(PixelRect(x: 7, y: 5, width: 1, height: 1), bgra: [0, 0, 255, 0]) // pure red in the bottom right corner
        renderer.upload(bigger, dirty: [PixelRect(x: 0, y: 0, width: 1, height: 1)]) // dirty is ignored because the texture is new
        #expect(renderer.textureSize == (8, 6))

        let target = try makeTarget(renderer, width: 80, height: 60)
        renderer.render(to: target, geometry: ViewportGeometry(remoteSize: CGSize(width: 8, height: 6), viewSize: CGSize(width: 80, height: 60)))
        #expect(isClose(readback(target)[55][75], (255, 0, 0)))
    }

    @Test func downscalingBlendsNeighboursWhileUpscalingStaysSharp() throws {
        let renderer = try makeRenderer()
        // A 4×4 black and white checkerboard, alternating every pixel.
        var board = try Framebuffer(width: 4, height: 4)
        for y in 0..<4 {
            for x in 0..<4 {
                let value: UInt8 = (x + y).isMultiple(of: 2) ? 255 : 0
                try board.write(PixelRect(x: x, y: y, width: 1, height: 1), bgra: [value, value, value, 0])
            }
        }
        renderer.upload(board)

        // Shrunk to 2×2 (scale 0.5): the center of each output pixel lies exactly between four texels, so it is the average, about 127.
        let small = try makeTarget(renderer, width: 2, height: 2)
        renderer.render(to: small, geometry: ViewportGeometry(remoteSize: CGSize(width: 4, height: 4), viewSize: CGSize(width: 2, height: 2)))
        let blended = readback(small)[0][0]
        #expect(isClose(blended, (127, 127, 127), 2), "downscaling must interpolate, got \(blended)")

        // Enlarged 10 times: still nearest pixel, each block has exactly one color.
        let large = try makeTarget(renderer, width: 40, height: 40)
        renderer.render(to: large, geometry: ViewportGeometry(remoteSize: CGSize(width: 4, height: 4), viewSize: CGSize(width: 40, height: 40)))
        let sharp = readback(large)
        #expect(isClose(sharp[5][5], (255, 255, 255)))
        #expect(isClose(sharp[5][15], (0, 0, 0)))
        #expect(isClose(sharp[0][9], (255, 255, 255)), "right at the block edge it is still the block's color, not blended")
    }

    @Test func drawingWithoutDataOnlyClears() throws {
        let renderer = try makeRenderer()
        let target = try makeTarget(renderer, width: 8, height: 8)
        renderer.render(
            to: target, geometry: ViewportGeometry(remoteSize: CGSize(width: 4, height: 2), viewSize: CGSize(width: 8, height: 8)),
            clearColor: MTLClearColor(red: 1, green: 0, blue: 0, alpha: 1)
        )
        #expect(isClose(readback(target)[4][4], (255, 0, 0)))
    }

    // MARK: Two alternating textures (anti-tearing, frames not retained)

    private func paint(_ screen: inout Framebuffer, _ rect: PixelRect, r: UInt8, g: UInt8, b: UInt8) throws {
        try screen.write(rect, bgra: [UInt8]((0..<rect.width * rect.height).flatMap { _ in [b, g, r, 0] }))
    }

    /// Three consecutive updates change three different places. Each update lands in a different texture, so the texture drawn last must make up for
    /// the regions that changed while we were writing to the other texture. If wrong, one of the three cells keeps the old color.
    @Test func alternatingTexturesStillShowEveryChange() throws {
        let renderer = try makeRenderer()
        var screen = try makeScreen()
        renderer.upload(screen)
        let a = PixelRect(x: 0, y: 0, width: 1, height: 1), b = PixelRect(x: 3, y: 0, width: 1, height: 1), c = PixelRect(x: 1, y: 1, width: 1, height: 1)
        try paint(&screen, a, r: 255, g: 0, b: 0)
        renderer.upload(screen, dirty: [a])
        try paint(&screen, b, r: 0, g: 255, b: 0)
        renderer.upload(screen, dirty: [b])
        try paint(&screen, c, r: 0, g: 0, b: 255)
        renderer.upload(screen, dirty: [c])

        let target = try makeTarget(renderer, width: 40, height: 20)
        renderer.render(to: target, geometry: ViewportGeometry(remoteSize: CGSize(width: 4, height: 2), viewSize: CGSize(width: 40, height: 20)))
        let image = readback(target)
        for y in 0..<2 {
            for x in 0..<4 {
                #expect(isClose(image[y * 10 + 5][x * 10 + 5], try #require(screen.rgb(x: x, y: y))), "pixel (\(x), \(y))")
            }
        }
    }

    /// A draw command waiting on the GPU (encoded, not finished) holds its texture; the next upload must write to the other texture.
    @Test func anUploadNeverWritesTheTextureTheGPUIsReading() throws {
        let renderer = try makeRenderer()
        var screen = try makeScreen()
        renderer.upload(screen)
        let target = try makeTarget(renderer, width: 40, height: 20)
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        let buffer = try #require(renderer.makeCommandBuffer())
        renderer.encode(into: buffer, pass: pass, geometry: ViewportGeometry(remoteSize: CGSize(width: 4, height: 2), viewSize: CGSize(width: 40, height: 20)))
        let busy = renderer.inFlightCounts
        #expect(busy.reduce(0, +) == 1, "one texture is being read")

        try paint(&screen, PixelRect(x: 0, y: 0, width: 4, height: 2), r: 9, g: 9, b: 9)
        renderer.upload(screen, dirty: [screen.bounds])
        // The second draw command must use the other texture (the one just written), not the busy one.
        let second = try #require(renderer.makeCommandBuffer())
        renderer.encode(into: second, pass: pass, geometry: ViewportGeometry(remoteSize: CGSize(width: 4, height: 2), viewSize: CGSize(width: 40, height: 20)))
        #expect(renderer.inFlightCounts == [1, 1], "the two draw commands use two different textures")

        buffer.commit(); second.commit()
        second.waitUntilCompleted(); buffer.waitUntilCompleted()
        // The completion handler runs asynchronously; wait for it to give back both textures.
        let deadline = Date().addingTimeInterval(2)
        while renderer.inFlightCounts != [0, 0], Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        #expect(renderer.inFlightCounts == [0, 0])
    }

    /// Resizing the screen midway while an old draw command is pending: the old command finishing must not wrongly decrement the new texture pair.
    @Test func resizingWhileTheGPUIsBusyKeepsTheCountsSane() throws {
        let renderer = try makeRenderer()
        renderer.upload(try makeScreen())
        let target = try makeTarget(renderer, width: 40, height: 20)
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        let old = try #require(renderer.makeCommandBuffer())
        renderer.encode(into: old, pass: pass, geometry: ViewportGeometry(remoteSize: CGSize(width: 4, height: 2), viewSize: CGSize(width: 40, height: 20)))
        renderer.upload(try Framebuffer(width: 8, height: 4)) // new size: recreate the texture pair
        #expect(renderer.inFlightCounts == [0, 0])
        old.commit(); old.waitUntilCompleted()
        let deadline = Date().addingTimeInterval(1)
        while Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        #expect(renderer.inFlightCounts == [0, 0], "must not go negative")
    }
}
