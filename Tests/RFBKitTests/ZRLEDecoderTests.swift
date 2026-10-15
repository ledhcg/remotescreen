import Foundation
import Testing
@testable import RFBKit

/// CPIXEL on the wire: 3 bytes B, G, R.
private func c(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> [UInt8] { [b, g, r] }

/// Decodes `bytes` (already-decompressed ZRLE data) into a new framebuffer of size `width`×`height`.
private func decode(_ bytes: [UInt8], rect: PixelRect, in size: (Int, Int)? = nil) throws -> Framebuffer {
    var buffer = try Framebuffer(width: size?.0 ?? rect.x + rect.width, height: size?.1 ?? rect.y + rect.height)
    try ZRLEDecoder.decodeTiles(bytes, rect: rect, into: &buffer)
    return buffer
}

private func row(_ buffer: Framebuffer, _ y: Int, channel: KeyPath<(r: UInt8, g: UInt8, b: UInt8), UInt8> = \.r) -> [UInt8] {
    (0..<buffer.width).map { buffer.rgb(x: $0, y: y)![keyPath: channel] }
}

/// Expected values in this test set were computed by hand following RFC 6143 section 7.7.6.
@Suite("ZRLE: each tile kind")
struct ZRLETileTests {
    @Test func rawTile() throws {
        let bytes = [0] + c(255, 0, 0) + c(0, 255, 0) + c(0, 0, 255) + c(10, 20, 30)
        let buffer = try decode(bytes, rect: PixelRect(x: 0, y: 0, width: 2, height: 2))
        #expect(buffer.rgb(x: 0, y: 0)! == (255, 0, 0))
        #expect(buffer.rgb(x: 1, y: 0)! == (0, 255, 0))
        #expect(buffer.rgb(x: 0, y: 1)! == (0, 0, 255))
        #expect(buffer.rgb(x: 1, y: 1)! == (10, 20, 30))
    }

    @Test func solidTileOnlyTouchesItsRectangle() throws {
        let buffer = try decode([1] + c(9, 8, 7), rect: PixelRect(x: 1, y: 1, width: 3, height: 2), in: (5, 4))
        #expect(buffer.rgb(x: 1, y: 1)! == (9, 8, 7))
        #expect(buffer.rgb(x: 3, y: 2)! == (9, 8, 7))
        #expect(buffer.rgb(x: 0, y: 0)! == (0, 0, 0))
        #expect(buffer.rgb(x: 4, y: 3)! == (0, 0, 0))
        #expect(buffer.rgb(x: 4, y: 1)! == (0, 0, 0)) // just right of the region
    }

    @Test func packedPaletteOneBitPerPixel() throws {
        // Palette of 2 colors, 10 pixels. Indices 1,0,1,0,1,0,1,0 | 1,1 → byte 0xAA, then 0b11 + padding = 0xC0.
        let bytes = [2] + c(255, 0, 0) + c(0, 0, 255) + [0xAA, 0xC0]
        let buffer = try decode(bytes, rect: PixelRect(x: 0, y: 0, width: 10, height: 1))
        #expect(row(buffer, 0, channel: \.b) == [255, 0, 255, 0, 255, 0, 255, 0, 255, 255])
    }

    @Test func packedPaletteTwoBitsPerPixel() throws {
        // 3 colors → 2 bits. Indices 0,1,2,1,0 → 00 01 10 01 | 00 → 0x19, 0x00.
        let bytes = [3] + c(1, 0, 0) + c(2, 0, 0) + c(3, 0, 0) + [0x19, 0x00]
        let buffer = try decode(bytes, rect: PixelRect(x: 0, y: 0, width: 5, height: 1))
        #expect(row(buffer, 0) == [1, 2, 3, 2, 1])
    }

    @Test func packedPaletteFourBitsPerPixelPadsEachRow() throws {
        // 5 colors → 4 bits. Each row of 3 pixels = 12 bits → 2 bytes. Row 0: 4,0,3 → 0x40,0x30. Row 1: 2,2,1 → 0x22,0x10.
        let palette = c(10, 0, 0) + c(20, 0, 0) + c(30, 0, 0) + c(40, 0, 0) + c(50, 0, 0)
        let buffer = try decode([5] + palette + [0x40, 0x30, 0x22, 0x10], rect: PixelRect(x: 0, y: 0, width: 3, height: 2))
        #expect(row(buffer, 0) == [50, 10, 40])
        #expect(row(buffer, 1) == [30, 30, 20])
    }

    @Test func plainRLEWithMultiByteRunLengths() throws {
        // Tile 20×20 = 400 pixels. Run 1: 300 pixels = 1 + (255 + 44) → bytes 255, 44. Run 2: 100 pixels = 1 + 99 → byte 99.
        let bytes = [0x80] + c(100, 0, 0) + [255, 44] + c(200, 0, 0) + [99]
        let buffer = try decode(bytes, rect: PixelRect(x: 0, y: 0, width: 20, height: 20))
        #expect(buffer.rgb(x: 19, y: 14)!.r == 100) // pixel 299 (counting from 0)
        #expect(buffer.rgb(x: 0, y: 15)!.r == 200) // pixel 300
        #expect(buffer.rgb(x: 19, y: 19)!.r == 200)
    }

    @Test func paletteRLE() throws {
        // sub = 0x80 | 2. Entry 0x00 = index 0, one pixel. Entry 0x81 + length 3 = index 1, 4 pixels.
        let bytes = [0x82] + c(1, 0, 0) + c(2, 0, 0) + [0x00, 0x81, 0x03, 0x00]
        let buffer = try decode(bytes, rect: PixelRect(x: 0, y: 0, width: 6, height: 1))
        #expect(row(buffer, 0) == [1, 2, 2, 2, 2, 1])
    }

    @Test func tilesAreOrderedRowMajorAndEdgeTilesAreSmaller() throws {
        // 70×66 has four tiles: 64×64, 6×64, 64×2, 6×2, in order left to right then top to bottom.
        var bytes: [UInt8] = []
        for red in 1...4 { bytes += [1] + c(UInt8(red), 0, 0) }
        let buffer = try decode(bytes, rect: PixelRect(x: 0, y: 0, width: 70, height: 66))
        #expect(buffer.rgb(x: 63, y: 63)!.r == 1)
        #expect(buffer.rgb(x: 64, y: 0)!.r == 2)
        #expect(buffer.rgb(x: 69, y: 63)!.r == 2)
        #expect(buffer.rgb(x: 0, y: 64)!.r == 3)
        #expect(buffer.rgb(x: 63, y: 65)!.r == 3)
        #expect(buffer.rgb(x: 64, y: 64)!.r == 4)
        #expect(buffer.rgb(x: 69, y: 65)!.r == 4)
    }

    @Test func rectangleNotAtTheOriginIsOffsetCorrectly() throws {
        let buffer = try decode([1] + c(77, 0, 0), rect: PixelRect(x: 10, y: 20, width: 2, height: 2), in: (16, 24))
        #expect(buffer.rgb(x: 10, y: 20)!.r == 77)
        #expect(buffer.rgb(x: 11, y: 21)!.r == 77)
        #expect(buffer.rgb(x: 9, y: 20)!.r == 0)
        #expect(buffer.rgb(x: 12, y: 21)!.r == 0)
    }
}

@Suite("ZRLE: bad data is rejected")
struct ZRLEMalformedTests {
    private let rect2x1 = PixelRect(x: 0, y: 0, width: 2, height: 1)

    @Test func paletteIndexOutOfRange() {
        // Palette of 3 colors but index 3 (bits 11) appears.
        let bytes = [3] + c(1, 0, 0) + c(2, 0, 0) + c(3, 0, 0) + [0b1100_0000]
        #expect(throws: RFBError.self) { try decode(bytes, rect: rect2x1) }
    }

    @Test func runOverflowingTheTile() {
        #expect(throws: RFBError.self) { try decode([0x80] + c(1, 0, 0) + [2], rect: rect2x1) } // run of 3 > 2 pixels
    }

    @Test(arguments: [17, 50, 127, 129])
    func unusedSubencodings(sub: UInt8) {
        #expect(throws: RFBError.self) { try decode([sub], rect: rect2x1) }
    }

    @Test func truncatedData() {
        #expect(throws: RFBError.self) { try decode([0] + c(1, 2, 3), rect: rect2x1) } // needs 2 CPIXELs, only 1 present
        #expect(throws: RFBError.self) { try decode([], rect: rect2x1) }
    }

    @Test func trailingBytesMeanTheStreamIsDesynchronised() {
        #expect(throws: RFBError.self) { try decode([1] + c(1, 2, 3) + [0], rect: rect2x1) }
    }

    @Test func rectangleOutsideTheFramebuffer() throws {
        var buffer = try Framebuffer(width: 4, height: 4)
        #expect(throws: RFBError.self) {
            try ZRLEDecoder.decodeTiles([1] + c(1, 2, 3), rect: PixelRect(x: 3, y: 0, width: 2, height: 1), into: &buffer)
        }
    }

    @Test func sizeBoundsAreGenerousForRealDataButFinite() {
        let rect = PixelRect(x: 0, y: 0, width: 2048, height: 1152)
        // The worst case for RLE is 4 bytes per pixel, and it must fit within the cap.
        #expect(ZRLEDecoder.maxInflatedSize(for: rect) >= rect.width * rect.height * 4)
        #expect(ZRLEDecoder.maxInflatedSize(for: rect) < rect.width * rect.height * 5)
        #expect(ZRLEDecoder.maxCompressedSize(for: rect) >= rect.width * rect.height * 4)
    }
}
