import Foundation
import Testing
@testable import RFBKit

/// Tiêu đề một hình chữ nhật trong FramebufferUpdate: x, y, rộng, cao (mỗi số 16-bit) rồi encoding (32-bit có dấu).
func rectHeader(_ x: UInt16, _ y: UInt16, _ w: UInt16, _ h: UInt16, encoding: Int32) -> [UInt8] {
    var data = Data()
    for value in [x, y, w, h] { data.appendBigEndian(value) }
    data.appendBigEndian(UInt32(bitPattern: encoding))
    return Array(data)
}

/// FramebufferUpdate: loại 0, đệm, số hình chữ nhật, rồi nội dung.
func update(rectCount: UInt16, _ body: [UInt8]) -> [UInt8] {
    [0, 0, UInt8(rectCount >> 8), UInt8(rectCount & 0xFF)] + body
}

func makeSession(_ incoming: [UInt8], width: UInt16 = 4, height: UInt16 = 2) throws -> (RFBSession, ScriptedByteStream) {
    let stream = ScriptedByteStream(incoming)
    let info = ServerInit(width: width, height: height, pixelFormat: .bgra8888, name: "test")
    return (try RFBSession(stream: stream, serverInfo: info), stream)
}

@Suite("RFBSession: gửi")
struct SessionSendTests {
    @Test func startSendsPixelFormatEncodingsAndFullRequestInOneWrite() async throws {
        let (session, stream) = try makeSession([])
        try await session.start(encodings: [.raw, .copyRect])

        let expected = ClientMessage.setPixelFormat(.bgra8888).wireBytes
            + ClientMessage.setEncodings([.raw, .copyRect]).wireBytes
            + Data([3, 0, 0, 0, 0, 0, 0, 4, 0, 2]) // không tăng dần, toàn khung 4x2
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

@Suite("RFBSession: nhận")
struct SessionReceiveTests {
    @Test func largeRawRectangleIsReadInBandsAndStillLandsInTheRightPlace() async throws {
        // 1500x1500x4 = 9 MB, lớn hơn `maxRawBandBytes` (4 MiB) nên phải qua nhiều dải; dải cuối ngắn hơn các dải trước.
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
        // Chép vùng (0,0) rộng 2 cao 1 xuống (2,1): sau Raw, nguồn đã có nội dung.
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
        // Khai báo 3 hình chữ nhật nhưng hình thứ hai là LastRect. Byte sau đó là một Bell, không bị nuốt.
        let body = rectHeader(0, 0, 1, 1, encoding: 0) + bgra(5, 5, 5) + rectHeader(0, 0, 0, 0, encoding: -224)
        let (session, _) = try makeSession(update(rectCount: 3, body) + [2])
        #expect(try await session.nextEvent() == .framebufferUpdate(dirty: [PixelRect(x: 0, y: 0, width: 1, height: 1)]))
        #expect(try await session.nextEvent() == .bell)
    }

    @Test func bellColourMapAndCutTextAreConsumedExactly() async throws {
        var incoming: [UInt8] = [2] // Bell
        // SetColourMap: loại 1, đệm 1, màu đầu (2 byte), số màu = 2 (2 byte), rồi 2 màu × 6 byte.
        incoming += [1, 0, 0, 0, 0, 2] + Array(repeating: 0xAB, count: 12)
        incoming += [3, 0, 0, 0, 0, 0, 0, 5, 0x68, 0xE9, 0x6C, 0x6C, 0x6F] // ServerCutText "héllo"
        incoming += [2] // Bell cuối. Nếu các message trước đọc sai độ dài thì đây sẽ lệch.
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
        let (session, _) = try makeSession(update(rectCount: 1, rectHeader(0, 0, 2, 1, encoding: 0) + bgra(1, 2, 3))) // thiếu 4 byte
        await #expect(throws: RFBError.connectionClosed) { try await session.nextEvent() }
    }
}
