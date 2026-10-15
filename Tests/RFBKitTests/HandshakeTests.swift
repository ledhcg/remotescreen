import Foundation
import Testing
@testable import RFBKit

/// Luồng giả: đọc từ một mảng byte dựng sẵn, ghi lại mọi thứ client gửi đi.
actor ScriptedByteStream: ByteStream {
    private var incoming: Data
    private(set) var written = Data()

    init(_ bytes: [UInt8]) { incoming = Data(bytes) }

    func read(exactly count: Int) throws -> Data {
        guard incoming.count >= count else { throw RFBError.connectionClosed }
        defer { incoming = Data(incoming.dropFirst(count)) }
        return Data(incoming.prefix(count))
    }

    func readSome(maxCount: Int) throws -> Data {
        guard !incoming.isEmpty else { throw RFBError.connectionClosed }
        return try read(exactly: min(maxCount, incoming.count))
    }

    func write(_ data: Data) { written.append(data) }
    func close() {}
}

private func ascii(_ text: String) -> [UInt8] { Array(text.utf8) }

@Suite("RFBVersion")
struct RFBVersionTests {
    @Test func parsesStandardVersion() throws {
        let version = try RFBVersion(parsing: Data(ascii("RFB 003.008\n")))
        #expect(version == .v3_8)
        #expect(version.wireString == "RFB 003.008\n")
    }

    @Test func appleVersionNegotiatesDownToThreeEight() throws {
        // Apple quảng cáo 003.889 (đã quan sát trên screensharingd thật).
        let version = try RFBVersion(parsing: Data(ascii("RFB 003.889\n")))
        #expect(version == RFBVersion(major: 3, minor: 889))
        #expect(try version.negotiated() == .v3_8)
    }

    @Test(arguments: [(7, RFBVersion.v3_7), (6, .v3_3), (3, .v3_3), (8, .v3_8)])
    func minorVersionMapping(minor: Int, expected: RFBVersion) throws {
        #expect(try RFBVersion(major: 3, minor: minor).negotiated() == expected)
    }

    @Test(arguments: ["", "HTTP/1.1 200\n", "RFB 003.008", "RFB 3.8\n", "RFB 003-008\n"])
    func rejectsMalformed(text: String) {
        #expect(throws: RFBError.self) { try RFBVersion(parsing: Data(ascii(text))) }
    }
}

@Suite("Handshake")
struct HandshakeTests {
    @Test func listsSecurityTypesIncludingUnknown() async throws {
        // Server 3.889 cho phép type 30 (ARD) và 33 (chưa biết, phải được giữ nguyên).
        let stream = ScriptedByteStream(ascii("RFB 003.889\n") + [2, 30, 33])
        let hello = try await Handshake.readServerHello(over: stream)

        #expect(hello.serverVersion == RFBVersion(major: 3, minor: 889))
        #expect(hello.negotiatedVersion == .v3_8)
        #expect(hello.securityTypes == [.appleRemoteDesktop, RFBSecurityType(rawValue: 33)])
        #expect(RFBSecurityType(rawValue: 33).knownName == nil)
        #expect(await stream.written == Data(ascii("RFB 003.008\n")))
    }

    @Test func version37ReadsTypeList() async throws {
        let stream = ScriptedByteStream(ascii("RFB 003.007\n") + [1, 1])
        let hello = try await Handshake.readServerHello(over: stream)
        #expect(hello.negotiatedVersion == .v3_7)
        #expect(hello.securityTypes == [.noAuthentication])
    }

    @Test func version33ServerPicksSingleType() async throws {
        let stream = ScriptedByteStream(ascii("RFB 003.003\n") + [0, 0, 0, 2])
        let hello = try await Handshake.readServerHello(over: stream)
        #expect(hello.negotiatedVersion == .v3_3)
        #expect(hello.securityTypes == [.vncAuthentication])
        #expect(await stream.written == Data(ascii("RFB 003.003\n")))
    }

    @Test func zeroTypesMeansRejectionWithReason() async {
        let reason = ascii("Too many attempts")
        // 1 byte đếm = 0, rồi 4 byte độ dài big-endian, rồi nội dung lý do.
        let stream = ScriptedByteStream(ascii("RFB 003.008\n") + [0, 0, 0, 0, UInt8(reason.count)] + reason)
        await #expect(throws: RFBError.serverRejected(reason: "Too many attempts")) {
            try await Handshake.readServerHello(over: stream)
        }
    }

    @Test func absurdReasonLengthIsRejected() async {
        let stream = ScriptedByteStream(ascii("RFB 003.008\n") + [0, 0xFF, 0xFF, 0xFF, 0xFF])
        await #expect(throws: RFBError.self) {
            try await Handshake.readServerHello(over: stream)
        }
    }

    @Test func truncatedStreamReportsConnectionClosed() async {
        let stream = ScriptedByteStream(ascii("RFB 003.008\n") + [3, 1])
        await #expect(throws: RFBError.connectionClosed) {
            try await Handshake.readServerHello(over: stream)
        }
    }
}
