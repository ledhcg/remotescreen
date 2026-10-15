import Foundation
import Testing
@testable import RFBKit

@Suite("ServerInit and PixelFormat")
struct ServerInitTests {
    /// 32 bpp, little-endian, true colour, 8 bits per channel, shift R=16 G=8 B=0.
    private let bgraBytes: [UInt8] = [32, 24, 0, 1, 0, 255, 0, 255, 0, 255, 16, 8, 0, 0, 0, 0]

    @Test func parsesCommonPixelFormat() throws {
        let format = try PixelFormat(parsing: Data(bgraBytes))
        #expect(format == .bgra8888)
    }

    @Test func wireBytesRoundTrip() throws {
        #expect(PixelFormat.bgra8888.wireBytes == Data(bgraBytes))
        let sixteenBit = PixelFormat(
            bitsPerPixel: 16, depth: 16, isBigEndian: true, isTrueColour: true,
            redMax: 31, greenMax: 63, blueMax: 31, redShift: 11, greenShift: 5, blueShift: 0
        )
        #expect(try PixelFormat(parsing: sixteenBit.wireBytes) == sixteenBit)
    }

    @Test func rejectsBadPixelFormats() {
        #expect(throws: RFBError.self) { try PixelFormat(parsing: Data(count: 15)) }
        var badBpp = bgraBytes
        badBpp[0] = 24
        #expect(throws: RFBError.self) { try PixelFormat(parsing: Data(badBpp)) }
    }

    @Test func performsClientInitAndReadsServerInit() async throws {
        let name = Array("Mac mini".utf8)
        // 1920x1080, then the 16-byte pixel format, then the name length (4 bytes) + name.
        let incoming: [UInt8] = [0x07, 0x80, 0x04, 0x38] + bgraBytes + [0, 0, 0, UInt8(name.count)] + name
        let stream = ScriptedByteStream(incoming)

        let info = try await Handshake.performInit(shared: true, over: stream)

        #expect(info == ServerInit(width: 1920, height: 1080, pixelFormat: .bgra8888, name: "Mac mini"))
        #expect(await stream.written == Data([1]))
    }

    @Test func exclusiveSessionSendsZero() async throws {
        let stream = ScriptedByteStream([0, 1, 0, 1] + bgraBytes + [0, 0, 0, 0])
        _ = try await Handshake.performInit(shared: false, over: stream)
        #expect(await stream.written == Data([0]))
    }

    @Test func rejectsAbsurdNameLengthAndTruncation() async {
        let huge = ScriptedByteStream([0, 1, 0, 1] + bgraBytes + [0xFF, 0xFF, 0xFF, 0xFF])
        await #expect(throws: RFBError.self) { try await Handshake.performInit(over: huge) }

        let truncated = ScriptedByteStream([0, 1, 0, 1] + bgraBytes + [0, 0, 0, 5, 0x41])
        await #expect(throws: RFBError.connectionClosed) { try await Handshake.performInit(over: truncated) }
    }
}
