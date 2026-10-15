import Foundation
import Testing
@testable import RFBKit

/// Header of one rectangle in a FramebufferUpdate: x, y, width, height (each 16-bit) then encoding (32-bit signed).
func rectHeader(_ x: UInt16, _ y: UInt16, _ w: UInt16, _ h: UInt16, encoding: Int32) -> [UInt8] {
    var data = Data()
    for value in [x, y, w, h] { data.appendBigEndian(value) }
    data.appendBigEndian(UInt32(bitPattern: encoding))
    return Array(data)
}

/// FramebufferUpdate: type 0, padding, rectangle count, then content.
func update(rectCount: UInt16, _ body: [UInt8]) -> [UInt8] {
    [0, 0, UInt8(rectCount >> 8), UInt8(rectCount & 0xFF)] + body
}

func makeSession(_ incoming: [UInt8], width: UInt16 = 4, height: UInt16 = 2) throws -> (RFBSession, ScriptedByteStream) {
    let stream = ScriptedByteStream(incoming)
    let info = ServerInit(width: width, height: height, pixelFormat: .bgra8888, name: "test")
    return (try RFBSession(stream: stream, serverInfo: info), stream)
}

@Suite("RFBSession: sending")
struct SessionSendTests {
    @Test func startSendsPixelFormatEncodingsAndFullRequestInOneWrite() async throws {
        let (session, stream) = try makeSession([])
        try await session.start(encodings: [.raw, .copyRect])

        let expected = ClientMessage.setPixelFormat(.bgra8888).wireBytes
            + ClientMessage.setEncodings([.raw, .copyRect]).wireBytes
            + Data([3, 0, 0, 0, 0, 0, 0, 4, 0, 2]) // non-incremental, full 4x2 frame
        #expect(await stream.written == expected)
    }

    @Test func requestUpdateIsIncrementalByDefault() async throws {
        let (session, stream) = try makeSession([])
        try await session.requestUpdate()
        #expect(await stream.written == Data([3, 1, 0, 0, 0, 0, 0, 4, 0, 2]))
    }

    @Test func rejectsEmptyFramebuffer() {
        #expect(throws: RFBError.self) { _ = try makeSession([], width: 0, height: 2) }
    }
}

@Suite("RFBSession: receiving")
struct SessionReceiveTests {
    @Test func largeRawRectangleIsReadInBandsAndStillLandsInTheRightPlace() async throws {
        // 1500x1500x4 = 9 MB, larger than `maxRawBandBytes` (4 MiB) so it must go through several bands; the last band is shorter than the earlier ones.
        let size = 1500
        var pixels: [UInt8] = []
        pixels.reserveCapacity(size * size * 4)
        for y in 0..<size {
            for x in 0..<size { pixels += bgra(UInt8(x % 251), UInt8(y % 251), UInt8((x + y) % 251)) }
        }
        #expect(pixels.count > RFBSession.maxRawBandBytes * 2)
        let body = rectHeader(0, 0, UInt16(size), UInt16(size), encoding: 0) + pixels
        let (session, _) = try makeSession(update(rectCount: 1, body), width: UInt16(size), height: UInt16(size))

        let event = try await session.nextEvent()

        #expect(event == .framebufferUpdate(dirty: [PixelRect(x: 0, y: 0, width: size, height: size)]))
        let buffer = await session.framebuffer
        for (x, y) in [(0, 0), (1499, 0), (3, 698), (3, 699), (700, 1398), (1499, 1499)] {
            #expect(buffer.rgb(x: x, y: y)! == (UInt8(x % 251), UInt8(y % 251), UInt8((x + y) % 251)), "(\(x), \(y))")
        }
    }

    @Test func decodesRawRectanglesIntoTheFramebuffer() async throws {
        let body = rectHeader(0, 0, 2, 1, encoding: 0) + bgra(255, 0, 0) + bgra(0, 255, 0)
            + rectHeader(2, 1, 2, 1, encoding: 0) + bgra(0, 0, 255) + bgra(9, 8, 7)
        let (session, _) = try makeSession(update(rectCount: 2, body))

        let event = try await session.nextEvent()

        #expect(event == .framebufferUpdate(dirty: [
            PixelRect(x: 0, y: 0, width: 2, height: 1), PixelRect(x: 2, y: 1, width: 2, height: 1),
        ]))
        let buffer = await session.framebuffer
        #expect(buffer.rgb(x: 0, y: 0)! == (255, 0, 0))
        #expect(buffer.rgb(x: 1, y: 0)! == (0, 255, 0))
        #expect(buffer.rgb(x: 2, y: 1)! == (0, 0, 255))
        #expect(buffer.rgb(x: 3, y: 1)! == (9, 8, 7))
        #expect(buffer.rgb(x: 3, y: 0)! == (0, 0, 0))
    }

    @Test func decodesCopyRectUsingEarlierContent() async throws {
        let raw = update(rectCount: 1, rectHeader(0, 0, 2, 1, encoding: 0) + bgra(11, 0, 0) + bgra(22, 0, 0))
        // Copy the region at (0,0) width 2 height 1 to (2,1): after Raw, the source already has content.
        let copy = update(rectCount: 1, rectHeader(2, 1, 2, 1, encoding: 1) + [0, 0, 0, 0])
        let (session, _) = try makeSession(raw + copy)

        _ = try await session.nextEvent()
        #expect(try await session.nextEvent() == .framebufferUpdate(dirty: [PixelRect(x: 2, y: 1, width: 2, height: 1)]))

        let buffer = await session.framebuffer
        #expect(buffer.rgb(x: 2, y: 1)!.r == 11)
        #expect(buffer.rgb(x: 3, y: 1)!.r == 22)
    }

    @Test func unknownEncodingFailsRatherThanDesynchronising() async throws {
        let (session, _) = try makeSession(update(rectCount: 1, rectHeader(0, 0, 1, 1, encoding: 99) + [1, 2, 3, 4]))
        await #expect(throws: RFBError.unsupportedEncoding(RFBEncoding(rawValue: 99))) { try await session.nextEvent() }
    }

    @Test func rawRectangleOutsideTheFramebufferIsRejected() async throws {
        let (session, _) = try makeSession(update(rectCount: 1, rectHeader(3, 0, 2, 1, encoding: 0) + Array(repeating: 0, count: 8)))
        await #expect(throws: RFBError.self) { try await session.nextEvent() }
    }

    @Test func desktopSizeResizesTheFramebuffer() async throws {
        let (session, _) = try makeSession(update(rectCount: 1, rectHeader(0, 0, 8, 6, encoding: -223)))
        _ = try await session.nextEvent()
        let buffer = await session.framebuffer
        #expect(buffer.width == 8)
        #expect(buffer.height == 6)
    }

    @Test func lastRectEndsTheUpdateEarly() async throws {
        // Declares 3 rectangles but the second is LastRect. The byte after it is a Bell, not swallowed.
        let body = rectHeader(0, 0, 1, 1, encoding: 0) + bgra(5, 5, 5) + rectHeader(0, 0, 0, 0, encoding: -224)
        let (session, _) = try makeSession(update(rectCount: 3, body) + [2])
        #expect(try await session.nextEvent() == .framebufferUpdate(dirty: [PixelRect(x: 0, y: 0, width: 1, height: 1)]))
        #expect(try await session.nextEvent() == .bell)
    }

    @Test func bellColourMapAndCutTextAreConsumedExactly() async throws {
        var incoming: [UInt8] = [2] // Bell
        // SetColourMap: type 1, padding 1, first color (2 bytes), color count = 2 (2 bytes), then 2 colors × 6 bytes.
        incoming += [1, 0, 0, 0, 0, 2] + Array(repeating: 0xAB, count: 12)
        incoming += [3, 0, 0, 0, 0, 0, 0, 5, 0x68, 0xE9, 0x6C, 0x6C, 0x6F] // ServerCutText "héllo"
        incoming += [2] // trailing Bell. If the earlier messages misread their lengths, this would be out of alignment.
        let (session, _) = try makeSession(incoming)

        #expect(try await session.nextEvent() == .bell)
        #expect(try await session.nextEvent() == .colourMapIgnored)
        #expect(try await session.nextEvent() == .serverCutText("héllo"))
        #expect(try await session.nextEvent() == .bell)
    }

    @Test func absurdClipboardLengthIsRejected() async throws {
        let (session, _) = try makeSession([3, 0, 0, 0, 0xFF, 0xFF, 0xFF, 0xFF])
        await #expect(throws: RFBError.self) { try await session.nextEvent() }
    }

    @Test func unknownMessageTypeIsRejected() async throws {
        let (session, _) = try makeSession([0x77])
        await #expect(throws: RFBError.self) { try await session.nextEvent() }
    }

    @Test func truncatedStreamReportsConnectionClosed() async throws {
        let (session, _) = try makeSession(update(rectCount: 1, rectHeader(0, 0, 2, 1, encoding: 0) + bgra(1, 2, 3))) // missing 4 bytes
        await #expect(throws: RFBError.connectionClosed) { try await session.nextEvent() }
    }
}
