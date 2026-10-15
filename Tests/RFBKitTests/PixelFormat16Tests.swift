import Foundation
import Testing
@testable import RFBKit

/// RGB565 little-endian trên đường truyền: byte thấp trước.
private func p565(_ value: UInt16) -> [UInt8] { [UInt8(value & 0xFF), UInt8(value >> 8)] }

@Suite("16 bit (RGB565): đổi màu")
struct RGB565ConversionTests {
    // Giá trị kỳ vọng tính tay: kênh 5 bit v → (v << 3) | (v >> 2), kênh 6 bit v → (v << 2) | (v >> 4).
    @Test(arguments: [
        (UInt32(0x0000), UInt32(0x000000)),   // đen
        (UInt32(0xFFFF), UInt32(0xFFFFFF)),   // trắng vẫn là trắng, không thành 0xF8FCF8
        (UInt32(0xF800), UInt32(0xFF0000)),   // đỏ thuần
        (UInt32(0x07E0), UInt32(0x00FF00)),   // lục thuần
        (UInt32(0x001F), UInt32(0x0000FF)),   // lam thuần
        (UInt32(0x8000), UInt32(0x840000)),   // đỏ giữa: 16 → 128 | 4 = 132 = 0x84
        (UInt32(0x0400), UInt32(0x008200)),   // lục giữa: 32 → 128 | 2 = 130 = 0x82
    ])
    func convertsExactly(value: UInt32, expected: UInt32) {
        #expect(PixelConversion.bgra(fromRGB565: value) == expected)
    }

    @Test func everyChannelValueMapsMonotonicallyAndSpansTheFullRange() {
        var lastRed: UInt32 = 0
        for r in 0...31 {
            let red = (PixelConversion.bgra(fromRGB565: UInt32(r) << 11) >> 16) & 0xFF
            #expect(red >= lastRed, "đỏ \(r) giảm so với mức trước")
            lastRed = red
        }
        #expect(lastRed == 255)
    }
}

@Suite("16 bit (RGB565): Raw và ZRLE")
struct RGB565DecodingTests {
    private func session(_ incoming: [UInt8], width: UInt16 = 4, height: UInt16 = 2) throws -> (RFBSession, ScriptedByteStream) {
        let stream = ScriptedByteStream(incoming)
        let info = ServerInit(width: width, height: height, pixelFormat: .bgra8888, name: "test")
        return (try RFBSession(stream: stream, serverInfo: info, pixelFormat: .rgb565), stream)
    }

    @Test func startAsksTheServerFor16BitPixels() async throws {
        let (session, stream) = try session([])
        try await session.start(encodings: [.raw])
        let sent = await stream.written
        #expect(sent.prefix(20) == ClientMessage.setPixelFormat(.rgb565).wireBytes)
        // 16 bit/pixel, độ sâu 16, little-endian, true colour, max 31/63/31, dịch 11/5/0
        #expect(Array(sent.dropFirst(4).prefix(13)) == [16, 16, 0, 1, 0, 31, 0, 63, 0, 31, 11, 5, 0])
    }

    @Test func rawRectanglesAreExpandedToBGRA() async throws {
        let body = rectHeader(0, 0, 2, 1, encoding: 0) + p565(0xF800) + p565(0x07E0)
            + rectHeader(2, 1, 2, 1, encoding: 0) + p565(0x001F) + p565(0xFFFF)
        let (session, _) = try session(update(rectCount: 2, body))
        _ = try await session.nextEvent()
        let buffer = await session.framebuffer
        #expect(buffer.rgb(x: 0, y: 0)! == (255, 0, 0))
        #expect(buffer.rgb(x: 1, y: 0)! == (0, 255, 0))
        #expect(buffer.rgb(x: 2, y: 1)! == (0, 0, 255))
        #expect(buffer.rgb(x: 3, y: 1)! == (255, 255, 255))
        #expect(await session.statistics.payloadBytes[.raw] == 8, "4 pixel x 2 byte, không phải 4 byte")
    }

    @Test func aTruncatedRawRectangleIsAnErrorNotAHang() async throws {
        let (session, _) = try session(update(rectCount: 1, rectHeader(0, 0, 2, 1, encoding: 0) + [1, 2, 3])) // thiếu 1 byte
        await #expect(throws: RFBError.self) { _ = try await session.nextEvent() }
    }

    @Test func unsupportedPixelFormatsAreRejectedUpFront() {
        let eightBit = PixelFormat(bitsPerPixel: 8, depth: 8, isBigEndian: false, isTrueColour: true,
                                   redMax: 7, greenMax: 7, blueMax: 3, redShift: 0, greenShift: 3, blueShift: 6)
        #expect(throws: RFBError.self) {
            _ = try RFBSession(
                stream: ScriptedByteStream([]), serverInfo: ServerInit(width: 4, height: 2, name: "t"), pixelFormat: eightBit
            )
        }
    }

    // ZRLE: CPIXEL 2 byte. Giá trị kỳ vọng tính tay từ RFC 6143 mục 7.7.6 và bảng đổi màu ở trên.
    private func decode(_ bytes: [UInt8], rect: PixelRect, size: (Int, Int)) throws -> Framebuffer {
        var buffer = try Framebuffer(width: size.0, height: size.1)
        try ZRLEDecoder.decodeTiles(bytes, rect: rect, layout: .rgb565, into: &buffer)
        return buffer
    }

    @Test func solidTileUsesATwoByteCPixel() throws {
        let buffer = try decode([1] + p565(0xF800), rect: PixelRect(x: 0, y: 0, width: 3, height: 2), size: (3, 2))
        for y in 0..<2 { for x in 0..<3 { #expect(buffer.rgb(x: x, y: y)! == (255, 0, 0)) } }
    }

    @Test func rawTileReadsTwoBytesPerPixel() throws {
        let bytes: [UInt8] = [0] + p565(0xF800) + p565(0x07E0) + p565(0x001F) + p565(0xFFFF)
        let buffer = try decode(bytes, rect: PixelRect(x: 0, y: 0, width: 2, height: 2), size: (2, 2))
        #expect(buffer.rgb(x: 0, y: 0)! == (255, 0, 0))
        #expect(buffer.rgb(x: 1, y: 0)! == (0, 255, 0))
        #expect(buffer.rgb(x: 0, y: 1)! == (0, 0, 255))
        #expect(buffer.rgb(x: 1, y: 1)! == (255, 255, 255))
    }

    @Test func packedPaletteTileUsesTwoByteEntries() throws {
        // Palette 2 màu (1 bit/pixel), tile 4x1: 1010 → chỉ số 1,0,1,0, đệm tới hết byte.
        let bytes: [UInt8] = [2] + p565(0xF800) + p565(0x001F) + [0b1010_0000]
        let buffer = try decode(bytes, rect: PixelRect(x: 0, y: 0, width: 4, height: 1), size: (4, 1))
        #expect(buffer.rgb(x: 0, y: 0)! == (0, 0, 255))
        #expect(buffer.rgb(x: 1, y: 0)! == (255, 0, 0))
        #expect(buffer.rgb(x: 2, y: 0)! == (0, 0, 255))
        #expect(buffer.rgb(x: 3, y: 0)! == (255, 0, 0))
    }

    @Test func plainRLETileUsesTwoByteColours() throws {
        // RLE thường (128): đỏ lặp 3 (độ dài 3 = byte 2), lam lặp 1 (byte 0), tile 4x1.
        let bytes: [UInt8] = [128] + p565(0xF800) + [2] + p565(0x001F) + [0]
        let buffer = try decode(bytes, rect: PixelRect(x: 0, y: 0, width: 4, height: 1), size: (4, 1))
        #expect((0..<3).allSatisfy { buffer.rgb(x: $0, y: 0)! == (255, 0, 0) })
        #expect(buffer.rgb(x: 3, y: 0)! == (0, 0, 255))
    }

    @Test func paletteRLETileUsesTwoByteEntries() throws {
        // Palette RLE (130 = 128 | 2 màu): mục 0 (đỏ) lặp dài (0x80|0, độ dài 2), mục 1 (lam) một pixel (1), mục 1 một pixel (1).
        let bytes: [UInt8] = [130] + p565(0xF800) + p565(0x001F) + [0x80, 1, 1, 1]
        let buffer = try decode(bytes, rect: PixelRect(x: 0, y: 0, width: 4, height: 1), size: (4, 1))
        #expect(buffer.rgb(x: 0, y: 0)! == (255, 0, 0))
        #expect(buffer.rgb(x: 1, y: 0)! == (255, 0, 0))
        #expect(buffer.rgb(x: 2, y: 0)! == (0, 0, 255))
        #expect(buffer.rgb(x: 3, y: 0)! == (0, 0, 255))
    }

    @Test func aThreeByteStreamIsNotAcceptedAs16BitData() {
        // Một tile thô 2x1 ở 24 bit cần 6 byte pixel; đọc theo 16 bit chỉ dùng 4 byte, nên còn thừa 2 byte → luồng lệch → lỗi.
        #expect(throws: RFBError.self) {
            _ = try decode([0, 1, 2, 3, 4, 5, 6], rect: PixelRect(x: 0, y: 0, width: 2, height: 1), size: (2, 1))
        }
    }
}
