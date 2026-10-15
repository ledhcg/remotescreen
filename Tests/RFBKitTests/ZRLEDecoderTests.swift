import Foundation
import Testing
@testable import RFBKit

/// CPIXEL trên đường truyền: 3 byte B, G, R.
private func c(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> [UInt8] { [b, g, r] }

/// Giải mã `bytes` (dữ liệu ZRLE đã giải nén) vào một framebuffer mới cỡ `width`×`height`.
private func decode(_ bytes: [UInt8], rect: PixelRect, in size: (Int, Int)? = nil) throws -> Framebuffer {
    var buffer = try Framebuffer(width: size?.0 ?? rect.x + rect.width, height: size?.1 ?? rect.y + rect.height)
    try ZRLEDecoder.decodeTiles(bytes, rect: rect, into: &buffer)
    return buffer
}

private func row(_ buffer: Framebuffer, _ y: Int, channel: KeyPath<(r: UInt8, g: UInt8, b: UInt8), UInt8> = \.r) -> [UInt8] {
    (0..<buffer.width).map { buffer.rgb(x: $0, y: y)![keyPath: channel] }
}

/// Các giá trị kỳ vọng trong bộ test này được tính tay theo RFC 6143 mục 7.7.6.
@Suite("ZRLE: từng loại tile")
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
        #expect(buffer.rgb(x: 4, y: 1)! == (0, 0, 0)) // ngay bên phải vùng
    }

    @Test func packedPaletteOneBitPerPixel() throws {
        // Palette 2 màu, 10 pixel. Chỉ số 1,0,1,0,1,0,1,0 | 1,1 → byte 0xAA, rồi 0b11 + đệm = 0xC0.
        let bytes = [2] + c(255, 0, 0) + c(0, 0, 255) + [0xAA, 0xC0]
        let buffer = try decode(bytes, rect: PixelRect(x: 0, y: 0, width: 10, height: 1))
        #expect(row(buffer, 0, channel: \.b) == [255, 0, 255, 0, 255, 0, 255, 0, 255, 255])
    }

    @Test func packedPaletteTwoBitsPerPixel() throws {
        // 3 màu → 2 bit. Chỉ số 0,1,2,1,0 → 00 01 10 01 | 00 → 0x19, 0x00.
        let bytes = [3] + c(1, 0, 0) + c(2, 0, 0) + c(3, 0, 0) + [0x19, 0x00]
        let buffer = try decode(bytes, rect: PixelRect(x: 0, y: 0, width: 5, height: 1))
        #expect(row(buffer, 0) == [1, 2, 3, 2, 1])
    }

    @Test func packedPaletteFourBitsPerPixelPadsEachRow() throws {
        // 5 màu → 4 bit. Mỗi hàng 3 pixel = 12 bit → 2 byte. Hàng 0: 4,0,3 → 0x40,0x30. Hàng 1: 2,2,1 → 0x22,0x10.
        let palette = c(10, 0, 0) + c(20, 0, 0) + c(30, 0, 0) + c(40, 0, 0) + c(50, 0, 0)
        let buffer = try decode([5] + palette + [0x40, 0x30, 0x22, 0x10], rect: PixelRect(x: 0, y: 0, width: 3, height: 2))
        #expect(row(buffer, 0) == [50, 10, 40])
        #expect(row(buffer, 1) == [30, 30, 20])
    }

    @Test func plainRLEWithMultiByteRunLengths() throws {
        // Tile 20×20 = 400 pixel. Lượt 1: 300 pixel = 1 + (255 + 44) → byte 255, 44. Lượt 2: 100 pixel = 1 + 99 → byte 99.
        let bytes = [0x80] + c(100, 0, 0) + [255, 44] + c(200, 0, 0) + [99]
        let buffer = try decode(bytes, rect: PixelRect(x: 0, y: 0, width: 20, height: 20))
        #expect(buffer.rgb(x: 19, y: 14)!.r == 100) // pixel thứ 299 (đếm từ 0)
        #expect(buffer.rgb(x: 0, y: 15)!.r == 200) // pixel thứ 300
        #expect(buffer.rgb(x: 19, y: 19)!.r == 200)
    }

    @Test func paletteRLE() throws {
        // sub = 0x80 | 2. Mục 0x00 = chỉ số 0, một pixel. Mục 0x81 + độ dài 3 = chỉ số 1, 4 pixel.
        let bytes = [0x82] + c(1, 0, 0) + c(2, 0, 0) + [0x00, 0x81, 0x03, 0x00]
        let buffer = try decode(bytes, rect: PixelRect(x: 0, y: 0, width: 6, height: 1))
        #expect(row(buffer, 0) == [1, 2, 2, 2, 2, 1])
    }

    @Test func tilesAreOrderedRowMajorAndEdgeTilesAreSmaller() throws {
        // 70×66 gồm bốn tile: 64×64, 6×64, 64×2, 6×2, theo thứ tự từ trái sang phải rồi từ trên xuống dưới.
        let bytes = [1] + c(1, 0, 0) + [1] + c(2, 0, 0) + [1] + c(3, 0, 0) + [1] + c(4, 0, 0)
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

@Suite("ZRLE: dữ liệu sai bị từ chối")
struct ZRLEMalformedTests {
    private let rect2x1 = PixelRect(x: 0, y: 0, width: 2, height: 1)

    @Test func paletteIndexOutOfRange() {
        // Palette 3 màu nhưng chỉ số 3 (bit 11) xuất hiện.
        let bytes = [3] + c(1, 0, 0) + c(2, 0, 0) + c(3, 0, 0) + [0b1100_0000]
        #expect(throws: RFBError.self) { try decode(bytes, rect: rect2x1) }
    }

    @Test func runOverflowingTheTile() {
        #expect(throws: RFBError.self) { try decode([0x80] + c(1, 0, 0) + [2], rect: rect2x1) } // lượt dài 3 > 2 pixel
    }

    @Test(arguments: [17, 50, 127, 129])
    func unusedSubencodings(sub: UInt8) {
        #expect(throws: RFBError.self) { try decode([sub], rect: rect2x1) }
    }

    @Test func truncatedData() {
        #expect(throws: RFBError.self) { try decode([0] + c(1, 2, 3), rect: rect2x1) } // cần 2 CPIXEL, chỉ có 1
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
        // Tệ nhất của RLE là 4 byte mỗi pixel, và phải nằm trong trần.
        #expect(ZRLEDecoder.maxInflatedSize(for: rect) >= rect.width * rect.height * 4)
        #expect(ZRLEDecoder.maxInflatedSize(for: rect) < rect.width * rect.height * 5)
        #expect(ZRLEDecoder.maxCompressedSize(for: rect) >= rect.width * rect.height * 4)
    }
}
