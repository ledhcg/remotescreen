import CoreGraphics
import CoreVideo
import Foundation
import Metal
import RFBKit
import Testing
@testable import RemoteDisplay

private typealias RGB = (r: UInt8, g: UInt8, b: UInt8)

/// Real-GPU tests of the compositor: sub-rectangle drawing, child placement and the video (YCbCr) path.
@MainActor
@Suite("SurfaceCompositor (real GPU)", .enabled(if: gpuTestsAvailable))
struct SurfaceCompositorTests {
    private func makeCompositor() throws -> SurfaceCompositor {
        try SurfaceCompositor(device: #require(MTLCreateSystemDefaultDevice()))
    }

    private func makeTarget(_ device: MTLDevice, width: Int, height: Int) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        return try #require(device.makeTexture(descriptor: descriptor))
    }

    private func pixel(_ texture: MTLTexture, _ x: Int, _ y: Int) -> RGB {
        var bytes = [UInt8](repeating: 0, count: 4)
        texture.getBytes(&bytes, bytesPerRow: 4, from: MTLRegionMake2D(x, y, 1, 1), mipmapLevel: 0)
        return (bytes[2], bytes[1], bytes[0])
    }

    private func isClose(_ a: RGB, _ b: RGB, _ tolerance: Int = 0) -> Bool {
        abs(Int(a.r) - Int(b.r)) <= tolerance && abs(Int(a.g) - Int(b.g)) <= tolerance && abs(Int(a.b) - Int(b.b)) <= tolerance
    }

    /// A screen whose pixels all differ (same recipe as the renderer tests).
    private func makeScreen(width: Int, height: Int) throws -> Framebuffer {
        var screen = try Framebuffer(width: width, height: height)
        for y in 0..<height {
            for x in 0..<width {
                let n = UInt8(y * width + x)
                try screen.write(PixelRect(x: x, y: y, width: 1, height: 1), bgra: [20 &* n &+ 10, 15 &* n &+ 5, 20 &* n &+ 40, 0])
            }
        }
        return screen
    }

    private func solid(_ width: Int, _ height: Int, b: UInt8, g: UInt8, r: UInt8) throws -> Framebuffer {
        var screen = try Framebuffer(width: width, height: height)
        try screen.write(PixelRect(x: 0, y: 0, width: width, height: height), bgra: (0..<(width * height)).flatMap { _ in [b, g, r, 0] })
        return screen
    }

    // MARK: uvRect / sourceRect

    @Test func geometrySourceRectDrawsOnlyThatPartFilledToTheView() throws {
        let compositor = try makeCompositor()
        let screen = try makeScreen(width: 4, height: 4)
        let surface = FramebufferSurface(device: compositor.device)
        surface.upload(screen)
        var geometry = ViewportGeometry(remoteSize: CGSize(width: 4, height: 4), viewSize: CGSize(width: 20, height: 20))
        geometry.setSourceRect(CGRect(x: 2, y: 1, width: 2, height: 2))
        let target = try makeTarget(compositor.device, width: 20, height: 20)
        compositor.render(to: target, main: surface, geometry: geometry)

        // Scale 10: each source pixel is a 10x10 block; the crop starts at Mac pixel (2, 1).
        for dy in 0..<2 {
            for dx in 0..<2 {
                let expected = try #require(screen.rgb(x: 2 + dx, y: 1 + dy))
                #expect(isClose(pixel(target, dx * 10 + 5, dy * 10 + 5), expected), "block (\(dx), \(dy))")
            }
        }
    }

    @Test func explicitUVRectStretchesTheSubRectangleOverTheQuad() throws {
        let compositor = try makeCompositor()
        let screen = try makeScreen(width: 4, height: 2)
        let surface = FramebufferSurface(device: compositor.device)
        surface.upload(screen)
        let geometry = ViewportGeometry(remoteSize: CGSize(width: 4, height: 2), viewSize: CGSize(width: 40, height: 20))
        let target = try makeTarget(compositor.device, width: 40, height: 20)
        // Right half of the surface: Mac pixels x = 2 and 3, each now 20 view pixels wide.
        compositor.render(to: target, main: surface, uvRect: CGRect(x: 0.5, y: 0, width: 0.5, height: 1), geometry: geometry)
        for (column, macX) in [(10, 2), (30, 3)] {
            for (row, macY) in [(5, 0), (15, 1)] {
                let expected = try #require(screen.rgb(x: macX, y: macY))
                #expect(isClose(pixel(target, column, row), expected), "Mac (\(macX), \(macY))")
            }
        }
    }

    // MARK: children

    @Test func childSurfaceIsPlacedAtItsOffsetOverTheMain() throws {
        let compositor = try makeCompositor()
        let main = FramebufferSurface(device: compositor.device)
        main.upload(try solid(4, 4, b: 0, g: 0, r: 200)) // red
        let childScreen = try makeScreen(width: 2, height: 2)
        let child = FramebufferSurface(device: compositor.device)
        child.upload(childScreen)
        let geometry = ViewportGeometry(remoteSize: CGSize(width: 4, height: 4), viewSize: CGSize(width: 40, height: 40)) // scale 10
        let target = try makeTarget(compositor.device, width: 40, height: 40)
        compositor.render(
            to: target, main: main, children: [ChildSurface(surface: child, offset: CGPoint(x: 1, y: 1))], geometry: geometry
        )

        #expect(isClose(pixel(target, 5, 5), (200, 0, 0)), "main outside the child")
        #expect(isClose(pixel(target, 35, 35), (200, 0, 0)))
        #expect(isClose(pixel(target, 5, 25), (200, 0, 0)))
        for dy in 0..<2 {
            for dx in 0..<2 {
                let expected = try #require(childScreen.rgb(x: dx, y: dy))
                #expect(isClose(pixel(target, 10 + dx * 10 + 5, 10 + dy * 10 + 5), expected), "child pixel (\(dx), \(dy))")
            }
        }
    }

    @Test func childFollowsTheCropAndZoom() throws {
        let compositor = try makeCompositor()
        let main = FramebufferSurface(device: compositor.device)
        main.upload(try solid(8, 8, b: 0, g: 0, r: 200))
        let child = FramebufferSurface(device: compositor.device)
        child.upload(try solid(2, 2, b: 0, g: 200, r: 0)) // green
        var geometry = ViewportGeometry(remoteSize: CGSize(width: 8, height: 8), viewSize: CGSize(width: 40, height: 40))
        geometry.setSourceRect(CGRect(x: 4, y: 4, width: 4, height: 4)) // scale 10, crop origin (4, 4)
        let target = try makeTarget(compositor.device, width: 40, height: 40)
        compositor.render(
            to: target, main: main, children: [ChildSurface(surface: child, offset: CGPoint(x: 5, y: 5))], geometry: geometry
        )
        #expect(isClose(pixel(target, 5, 5), (200, 0, 0)))
        #expect(isClose(pixel(target, 15, 15), (0, 200, 0)), "child at source (5, 5) lands at view (10...30)")
        #expect(isClose(pixel(target, 35, 35), (200, 0, 0)))
    }

    @Test func surfaceWithoutAFrameDrawsNothingAndNoCursor() throws {
        let compositor = try makeCompositor()
        compositor.setCursor(.defaultArrow)
        let empty = FramebufferSurface(device: compositor.device)
        let geometry = ViewportGeometry(remoteSize: CGSize(width: 4, height: 4), viewSize: CGSize(width: 20, height: 20))
        let target = try makeTarget(compositor.device, width: 20, height: 20)
        compositor.render(to: target, main: empty, geometry: geometry, pointer: (x: 1, y: 1), clearColor: MTLClearColor(red: 0, green: 0, blue: 1, alpha: 1))
        #expect(isClose(pixel(target, 10, 10), (0, 0, 255)))
        #expect(isClose(pixel(target, 2, 2), (0, 0, 255)))
    }

    // MARK: video

    /// BT.709 video range, computed independently of the shader.
    private func expectedRGB(y: Int, cb: Int, cr: Int, bitDepth: Int = 8) -> RGB {
        let shift = Double(1 << (bitDepth - 8))
        let luma = (Double(y) - 16 * shift) / (219 * shift)
        let u = (Double(cb) - 128 * shift) / (224 * shift)
        let v = (Double(cr) - 128 * shift) / (224 * shift)
        func byte(_ value: Double) -> UInt8 { UInt8((min(max(value, 0), 1) * 255).rounded()) }
        return (byte(luma + 1.5748 * v), byte(luma - 0.1873 * u - 0.4681 * v), byte(luma + 1.8556 * u))
    }

    /// 4x4 video frame: four 2x2 blocks, each with its own Y, Cb and Cr (codes at the given bit depth, 8 or 10).
    private func makeVideoFrame(bitDepth: Int, blocks: [(y: Int, cb: Int, cr: Int)]) throws -> CVPixelBuffer {
        let format = bitDepth == 8 ? kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange : kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        let attributes: [CFString: Any] = [kCVPixelBufferMetalCompatibilityKey: true, kCVPixelBufferIOSurfacePropertiesKey: [String: Any]()]
        var buffer: CVPixelBuffer?
        #expect(CVPixelBufferCreate(kCFAllocatorDefault, 4, 4, format, attributes as CFDictionary, &buffer) == kCVReturnSuccess)
        let pixelBuffer = try #require(buffer)
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        let bytesPerSample = bitDepth == 8 ? 1 : 2
        func store(_ base: UnsafeMutableRawPointer, offset: Int, code: Int) {
            if bitDepth == 8 {
                base.storeBytes(of: UInt8(code), toByteOffset: offset, as: UInt8.self)
            } else {
                base.storeBytes(of: UInt16(code << 6), toByteOffset: offset, as: UInt16.self) // 10-bit code in the top bits
            }
        }
        let luma = try #require(CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0))
        let lumaStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        let chroma = try #require(CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1))
        let chromaStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
        for y in 0..<4 {
            for x in 0..<4 {
                store(luma, offset: y * lumaStride + x * bytesPerSample, code: blocks[(y / 2) * 2 + x / 2].y)
            }
        }
        for by in 0..<2 {
            for bx in 0..<2 {
                let block = blocks[by * 2 + bx]
                store(chroma, offset: by * chromaStride + bx * 2 * bytesPerSample, code: block.cb)
                store(chroma, offset: by * chromaStride + (bx * 2 + 1) * bytesPerSample, code: block.cr)
            }
        }
        return pixelBuffer
    }

    private func checkVideo(bitDepth: Int) throws {
        let shift = 1 << (bitDepth - 8)
        // Gray, red-ish, green-ish, blue-ish, in 8-bit codes then scaled to the depth under test.
        let base: [(y: Int, cb: Int, cr: Int)] = [(126, 128, 128), (63, 102, 240), (173, 42, 26), (32, 240, 118)]
        let blocks = base.map { (y: $0.y * shift, cb: $0.cb * shift, cr: $0.cr * shift) }
        let pixelBuffer = try makeVideoFrame(bitDepth: bitDepth, blocks: blocks)

        let compositor = try makeCompositor()
        let video = try VideoSurface(device: compositor.device)
        #expect(video.update(pixelBuffer))
        #expect(video.size == (4, 4))
        #expect(video.pixelLayout == .ycbcr420(bitDepth: bitDepth))

        let geometry = ViewportGeometry(remoteSize: CGSize(width: 4, height: 4), viewSize: CGSize(width: 40, height: 40))
        let target = try makeTarget(compositor.device, width: 40, height: 40)
        compositor.render(to: target, main: video, geometry: geometry)
        for (index, block) in blocks.enumerated() {
            let center = (x: (index % 2) * 20 + 10, y: (index / 2) * 20 + 10)
            let expected = expectedRGB(y: block.y, cb: block.cb, cr: block.cr, bitDepth: bitDepth)
            let actual = pixel(target, center.x, center.y)
            #expect(isClose(actual, expected, 3), "block \(index) at \(bitDepth) bit: got \(actual), expected \(expected)")
        }
    }

    @Test func videoSurface8BitConvertsBT709VideoRange() throws {
        try checkVideo(bitDepth: 8)
    }

    @Test func videoSurface10BitConvertsBT709VideoRange() throws {
        try checkVideo(bitDepth: 10)
    }

    @Test func videoSurfaceRejectsOtherPixelFormats() throws {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 4, 4, kCVPixelFormatType_32BGRA, nil, &buffer)
        let video = try VideoSurface(device: #require(MTLCreateSystemDefaultDevice()))
        #expect(video.update(try #require(buffer)) == false)
        #expect(video.size == (0, 0))
    }

    @Test func videoCropAndChildBgraSurfaceCompose() throws {
        let compositor = try makeCompositor()
        let video = try VideoSurface(device: compositor.device)
        let gray = (y: 126, cb: 128, cr: 128)
        #expect(video.update(try makeVideoFrame(bitDepth: 8, blocks: [gray, gray, gray, gray])))
        let menu = FramebufferSurface(device: compositor.device)
        menu.upload(try solid(2, 2, b: 0, g: 0, r: 250))
        let geometry = ViewportGeometry(remoteSize: CGSize(width: 4, height: 4), viewSize: CGSize(width: 40, height: 40))
        let target = try makeTarget(compositor.device, width: 40, height: 40)
        compositor.render(to: target, main: video, children: [ChildSurface(surface: menu, offset: CGPoint(x: 2, y: 2))], geometry: geometry)
        #expect(isClose(pixel(target, 5, 5), expectedRGB(y: 126, cb: 128, cr: 128), 3))
        #expect(isClose(pixel(target, 30, 30), (250, 0, 0)))
    }
}
