import Foundation
import Testing
@testable import RFBKit

/// Little-endian RGB565 on the wire: low byte first.
private func p565(_ value: UInt16) -> [UInt8] { [UInt8(value & 0xFF), UInt8(value >> 8)] }

@Suite("16 bit (RGB565): color conversion")
struct RGB565ConversionTests {
    // Expected values computed by hand: 5-bit channel v → (v << 3) | (v >> 2), 6-bit channel v → (v << 2) | (v >> 4).
    @Test(arguments: [
        (UInt32(0x0000), UInt32(0x000000)),   // black
        (UInt32(0xFFFF), UInt32(0xFFFFFF)),   // white stays white, does not become 0xF8FCF8
        (UInt32(0xF800), UInt32(0xFF0000)),   // pure red
        (UInt32(0x07E0), UInt32(0x00FF00)),   // pure green
        (UInt32(0x001F), UInt32(0x0000FF)),   // pure blue
        (UInt32(0x8000), UInt32(0x840000)),   // mid red: 16 → 128 | 4 = 132 = 0x84
        (UInt32(0x0400), UInt32(0x008200)),   // mid green: 32 → 128 | 2 = 130 = 0x82
    ])
    func convertsExactly(value: UInt32, expected: UInt32) {
        #expect(PixelConversion.bgra(fromRGB565: value) == expected)
    }

    @Test func everyChannelValueMapsMonotonicallyAndSpansTheFullRange() {
        var lastRed: UInt32 = 0
        for r in 0...31 {
            let red = (PixelConversion.bgra(fromRGB565: UInt32(r) << 11) >> 16) & 0xFF
            #expect(red >= lastRed, "red \(r) decreased compared with the previous level")
            lastRed = red
        }
        #expect(lastRed == 255)
    }
}

@Suite("16 bit (RGB565): Raw and ZRLE")
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
        // 16 bits/pixel, depth 16, little-endian, true colour, max 31/63/31, shift 11/5/0
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
        #expect(await session.statistics.payloadBytes[.raw] == 8, "4 pixels x 2 bytes, not 4 bytes")
    }

    @Test func aTruncatedRawRectangleIsAnErrorNotAHang() async throws {
        let (session, _) = try session(update(rectCount: 1, rectHeader(0, 0, 2, 1, encoding: 0) + [1, 2, 3])) // missing 1 byte
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

    // ZRLE: 2-byte CPIXEL. Expected values computed by hand from RFC 6143 section 7.7.6 and the conversion table above.
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
        // Palette of 2 colors (1 bit/pixel), 4x1 tile: 1010 → indices 1,0,1,0, padded to the end of the byte.
        let bytes: [UInt8] = [2] + p565(0xF800) + p565(0x001F) + [0b1010_0000]
        let buffer = try decode(bytes, rect: PixelRect(x: 0, y: 0, width: 4, height: 1), size: (4, 1))
        #expect(buffer.rgb(x: 0, y: 0)! == (0, 0, 255))
        #expect(buffer.rgb(x: 1, y: 0)! == (255, 0, 0))
        #expect(buffer.rgb(x: 2, y: 0)! == (0, 0, 255))
        #expect(buffer.rgb(x: 3, y: 0)! == (255, 0, 0))
    }

    @Test func plainRLETileUsesTwoByteColours() throws {
        // Plain RLE (128): red repeated 3 (length 3 = byte 2), blue repeated 1 (byte 0), 4x1 tile.
        let bytes: [UInt8] = [128] + p565(0xF800) + [2] + p565(0x001F) + [0]
        let buffer = try decode(bytes, rect: PixelRect(x: 0, y: 0, width: 4, height: 1), size: (4, 1))
        #expect((0..<3).allSatisfy { buffer.rgb(x: $0, y: 0)! == (255, 0, 0) })
        #expect(buffer.rgb(x: 3, y: 0)! == (0, 0, 255))
    }

    @Test func paletteRLETileUsesTwoByteEntries() throws {
        // Palette RLE (130 = 128 | 2 colors): entry 0 (red) long run (0x80|0, length 2), entry 1 (blue) one pixel (1), entry 1 one pixel (1).
        let bytes: [UInt8] = [130] + p565(0xF800) + p565(0x001F) + [0x80, 1, 1, 1]
        let buffer = try decode(bytes, rect: PixelRect(x: 0, y: 0, width: 4, height: 1), size: (4, 1))
        #expect(buffer.rgb(x: 0, y: 0)! == (255, 0, 0))
        #expect(buffer.rgb(x: 1, y: 0)! == (255, 0, 0))
        #expect(buffer.rgb(x: 2, y: 0)! == (0, 0, 255))
        #expect(buffer.rgb(x: 3, y: 0)! == (0, 0, 255))
    }

    @Test func aThreeByteStreamIsNotAcceptedAs16BitData() {
        // A raw 2x1 tile at 24 bit needs 6 pixel bytes; read as 16 bit it uses only 4 bytes, leaving 2 extra bytes → stream out of sync → error.
        #expect(throws: RFBError.self) {
            _ = try decode([0, 1, 2, 3, 4, 5, 6], rect: PixelRect(x: 0, y: 0, width: 2, height: 1), size: (2, 1))
        }
    }
}
