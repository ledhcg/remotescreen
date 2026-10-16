import CoreGraphics
import Foundation
import ImageIO
import Metal
import Testing
import UniformTypeIdentifiers
@testable import RemoteDisplay

@Suite("BGRA image decoding")
struct BGRAImageDecoderTests {
    /// A PNG of `width` x `height` pixels, all the same RGBA colour (straight alpha).
    private func png(width: Int, height: Int, red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8 = 255) -> Data {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for index in 0..<(width * height) {
            pixels[index * 4] = red; pixels[index * 4 + 1] = green; pixels[index * 4 + 2] = blue; pixels[index * 4 + 3] = alpha
        }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        let image = CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )!
        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        return output as Data
    }

    @Test func decodesToPremultipliedBGRA() throws {
        let data = png(width: 3, height: 2, red: 10, green: 20, blue: 30)
        let image = try #require(BGRAImageDecoder.decode(data))
        #expect(image.width == 3 && image.height == 2)
        #expect(image.bgra.count == 24)
        #expect(Array(image.bgra[0..<4]) == [30, 20, 10, 255]) // B G R A
    }

    @Test func transparentPixelsStayFullyTransparent() throws {
        let image = try #require(BGRAImageDecoder.decode(png(width: 1, height: 1, red: 0, green: 0, blue: 0, alpha: 0)))
        #expect(image.bgra == [0, 0, 0, 0])
    }

    @Test func garbageTruncatedAndEmptyDataAreRejected() throws {
        #expect(BGRAImageDecoder.decode(Data()) == nil)
        #expect(BGRAImageDecoder.decode(Data(repeating: 0x41, count: 64)) == nil)
        let valid = png(width: 4, height: 4, red: 1, green: 2, blue: 3)
        #expect(BGRAImageDecoder.decode(valid.prefix(valid.count / 2)) == nil)
    }

    @Test func oversizedPicturesAreRejectedBeforeAllocation() {
        // 5000 x 1 is a few KiB as PNG but exceeds the side limit.
        #expect(BGRAImageDecoder.decode(png(width: 5000, height: 1, red: 0, green: 0, blue: 0)) == nil)
        #expect(BGRAImageDecoder.decode(png(width: 100, height: 100, red: 0, green: 0, blue: 0), maxDimension: 64) == nil)
    }

    @Test func aPNGHeaderClaimingAHugeSizeIsRejected() {
        var data = png(width: 2, height: 2, red: 1, green: 1, blue: 1)
        // IHDR width and height are the 8 bytes at offset 16.
        let huge: [UInt8] = [0x7F, 0xFF, 0xFF, 0xFF, 0x7F, 0xFF, 0xFF, 0xFF]
        data.replaceSubrange(16..<24, with: huge)
        #expect(BGRAImageDecoder.decode(data) == nil)
    }

    @Test func cursorHotspotIsClampedIntoTheImage() throws {
        let data = png(width: 8, height: 8, red: 255, green: 255, blue: 255)
        let cursor = try #require(BGRAImageDecoder.decodeCursor(data, hotspotX: 100, hotspotY: -5))
        #expect(cursor.hotspotX == 7 && cursor.hotspotY == 0)
        #expect(BGRAImageDecoder.decodeCursor(data, hotspotX: .nan, hotspotY: .infinity)?.hotspotX == 0)
        // Larger than a cursor may be.
        #expect(BGRAImageDecoder.decodeCursor(png(width: 1100, height: 2, red: 0, green: 0, blue: 0), hotspotX: 0, hotspotY: 0) == nil)
    }

    @Test(.enabled(if: gpuTestsAvailable)) @MainActor func surfaceKeepsTheLatestPictureAndRejectsInconsistentOnes() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let surface = BGRAImageSurface(device: device)
        #expect(surface.size == (0, 0))
        #expect(surface.update(DecodedBGRAImage(width: 2, height: 2, bgra: [UInt8](repeating: 255, count: 16))))
        #expect(surface.size == (2, 2))
        #expect(!surface.update(DecodedBGRAImage(width: 2, height: 2, bgra: [1, 2, 3])))
        #expect(surface.size == (2, 2))
    }
}
