import Foundation
import RFBCrypto
import Testing
@testable import RFBKit

private let okResult: [UInt8] = [0, 0, 0, 0]

@Suite("Xác thực: None và VNC")
struct SimpleAuthenticatorTests {
    @Test func vncAuthenticationRespondsWithDESAndReadsResult() async throws {
        let challenge = Data((0..<16).map { UInt8($0) })
        let stream = ScriptedByteStream(Array(challenge) + okResult)

        try await Authenticator.authenticate(
            type: .vncAuthentication, version: .v3_8,
            credentials: RFBCredentials(password: "password"), over: stream
        )

        // Phần DES đã được đối chiếu với OpenSSL trong RFBCryptoTests, ở đây kiểm tra luồng gửi nhận.
        #expect(await stream.written == (try VNCAuthentication.response(to: challenge, password: "password")))
    }

    @Test func noneReadsResultOnlyFromVersion38() async throws {
        let silent = ScriptedByteStream([])
        try await Authenticator.authenticate(type: .noAuthentication, version: .v3_7, credentials: RFBCredentials(), over: silent)

        let stream38 = ScriptedByteStream([])
        await #expect(throws: RFBError.connectionClosed) {
            try await Authenticator.authenticate(type: .noAuthentication, version: .v3_8, credentials: RFBCredentials(), over: stream38)
        }

        let ok38 = ScriptedByteStream(okResult)
        try await Authenticator.authenticate(type: .noAuthentication, version: .v3_8, credentials: RFBCredentials(), over: ok38)
    }

    @Test func failureCarriesReasonFromVersion38() async {
        let reason = Array("Wrong password".utf8)
        let stream = ScriptedByteStream(Array(Data(count: 16)) + [0, 0, 0, 1, 0, 0, 0, UInt8(reason.count)] + reason)
        await #expect(throws: RFBError.authenticationFailed(reason: "Wrong password")) {
            try await Authenticator.authenticate(
                type: .vncAuthentication, version: .v3_8, credentials: RFBCredentials(password: "x"), over: stream
            )
        }
    }

    @Test func failureHasNoReasonBefore38() async {
        // Nếu code cố đọc lý do ở 3.7, luồng cạn sẽ ném connectionClosed thay vì authenticationFailed.
        let stream = ScriptedByteStream(Array(Data(count: 16)) + [0, 0, 0, 1])
        await #expect(throws: RFBError.authenticationFailed(reason: "xác thực thất bại")) {
            try await Authenticator.authenticate(
                type: .vncAuthentication, version: .v3_7, credentials: RFBCredentials(password: "x"), over: stream
            )
        }
    }

    @Test func unknownAppleTypesAreRejectedExplicitly() async {
        let type = RFBSecurityType(rawValue: 33)
        await #expect(throws: RFBError.unsupportedSecurityType(type)) {
            try await Authenticator.authenticate(
                type: type, version: .v3_8, credentials: RFBCredentials(), over: ScriptedByteStream([])
            )
        }
    }
}

@Suite("Xác thực: Apple Remote Desktop (type 30)")
struct ARDAuthenticatorTests {
    /// Server giả dùng số nguyên tố 4096-bit THẬT lấy từ screensharingd nhưng khóa riêng của test.
    private struct MockServer {
        let prime = BigUInt(bigEndianBytes: Data(hex: RealServerFixture.primeAndPublic).prefix(512))
        let secret = BigUInt(bigEndianBytes: (try? SecureRandom.bytes(32)) ?? [7])
        var publicKey: BigUInt { BigUInt(5).modPow(secret, modulus: prime) }

        var hello: [UInt8] {
            Array(Data(hex: RealServerFixture.header)) + prime.bigEndianBytes(paddedTo: 512) + publicKey.bigEndianBytes(paddedTo: 512)
        }

        /// Giải mã những gì client gửi, đóng vai server.
        func decrypt(_ written: Data) throws -> (username: String, password: String) {
            #expect(written.count == 128 + 512)
            let encrypted = written.prefix(128)
            let clientPublic = BigUInt(bigEndianBytes: written.suffix(512))
            let shared = clientPublic.modPow(secret, modulus: prime)
            let key = MD5.hash(Data(shared.bigEndianBytes(paddedTo: 512)))
            let block = try AES128ECB.decrypt(Data(encrypted), key: key)
            func field(_ range: Range<Int>) -> String {
                String(decoding: block[range].prefix { $0 != 0 }, as: UTF8.self)
            }
            return (field(0..<64), field(64..<128))
        }
    }

    @Test func serverRecoversCredentialsSentByClient() async throws {
        let server = MockServer()
        let stream = ScriptedByteStream(server.hello + okResult)

        try await Authenticator.authenticate(
            type: .appleRemoteDesktop, version: .v3_8,
            credentials: RFBCredentials(username: "alice", password: "mật khẩu thử"), over: stream
        )

        let recovered = try server.decrypt(await stream.written)
        #expect(recovered.username == "alice")
        #expect(recovered.password == "mật khẩu thử")
    }

    @Test func acceptsTheRealServersOwnHello() async throws {
        // Không thể kiểm chứng server chấp nhận (cần mật khẩu thật), nhưng toàn bộ tham số thật
        // phải đi qua các bước kiểm tra và tính toán ở kích thước 4096-bit mà không lỗi.
        let hello = Array(Data(hex: RealServerFixture.header)) + Array(Data(hex: RealServerFixture.primeAndPublic))
        let stream = ScriptedByteStream(hello + okResult)

        try await Authenticator.authenticate(
            type: .appleRemoteDesktop, version: .v3_8,
            credentials: RFBCredentials(username: "u", password: "p"), over: stream
        )
        #expect(await stream.written.count == 128 + 512)
    }

    @Test func rejectsWeakOrMalformedKeyExchange() async throws {
        func hello(generator: UInt16 = 5, keyLength: Int = 128, prime: BigUInt? = nil, server: BigUInt = BigUInt(3)) -> [UInt8] {
            let primeValue = prime ?? BigUInt(bigEndianBytes: [UInt8](repeating: 0xFF, count: keyLength))
            return [UInt8(generator >> 8), UInt8(generator & 0xFF), UInt8(keyLength >> 8), UInt8(keyLength & 0xFF)]
                + primeValue.bigEndianBytes(paddedTo: keyLength) + server.bigEndianBytes(paddedTo: keyLength)
        }
        let credentials = RFBCredentials(username: "u", password: "p")

        let cases: [(String, [UInt8])] = [
            ("khóa 512-bit quá ngắn", hello(keyLength: 64)),
            ("generator 1", hello(generator: 1)),
            ("khóa server = 1", hello(server: BigUInt(1))),
            ("số nguyên tố chẵn", hello(prime: BigUInt(bigEndianBytes: [UInt8](repeating: 0xFF, count: 127) + [0xFE]))),
            ("khóa dài 4096 byte", [0, 5, 0x10, 0x00]),
            ("1024-bit không còn đủ mạnh", hello(keyLength: 128, prime: BigUInt(bigEndianBytes: Data(hex: RealServerFixture.primeAndPublic).prefix(128)))),
            ("2048-bit lẻ nhưng là hợp số", hello(keyLength: 256, prime: BigUInt(bigEndianBytes: [UInt8](repeating: 0xFF, count: 256)))),
        ]
        for (name, bytes) in cases {
            let stream = ScriptedByteStream(bytes + okResult)
            await #expect(throws: RFBError.self, "\(name)") {
                try await Authenticator.authenticate(type: .appleRemoteDesktop, version: .v3_8, credentials: credentials, over: stream)
            }
            #expect(await stream.written.isEmpty, "\(name): client không được gửi gì khi tham số bị từ chối")
        }
    }

    @Test func unknownButGenuinelyPrime2048BitGroupIsAccepted() async throws {
        let prime = BigUInt(bigEndianBytes: Data(hex: "b4196c597b58620200883732298e7fb6a266500a4be2aa484391b66fa291319450e25445f54c1eb574953e65abd4752caee9e699aabba044112f487326cf64a773d8792c783f82203a0b86d353b09fe1302f3d401f48ae8251cbe73414d57a6aa8cbf201ddf5a20ddb83560689cff98dfed5c65220d348592a5b8c1a540093bd431ba5ef7d25c8956949a0275a47b50db3447ac72a3d8ebb836046ff273c76bf2dcbee51e9593cb2bff216179c24b285e8e5062ef80216ad38d611dfb628763fd308512baa7adeb9bf8bb2972f1848101088ef9195c60fcc94230d7c29efd10e1be218992bb710e3bd03ceff41e1e7f6d410d8ee650170457c6281bd76a4d91f"))
        let secret = BigUInt(bigEndianBytes: (try? SecureRandom.bytes(32)) ?? [7])
        let hello = [0, 5, 1, 0] + prime.bigEndianBytes(paddedTo: 256) + BigUInt(5).modPow(secret, modulus: prime).bigEndianBytes(paddedTo: 256)
        let stream = ScriptedByteStream(hello + okResult)
        try await Authenticator.authenticate(
            type: .appleRemoteDesktop, version: .v3_8, credentials: RFBCredentials(username: "u", password: "p"), over: stream
        )
        #expect(await stream.written.count == 128 + 256)
    }

    @Test func primalityTestAgreesWithKnownValues() throws {
        for prime: UInt64 in [2, 3, 5, 97, 7919, 2_147_483_647, 18_446_744_073_709_551_557] {
            #expect(try BigUInt(prime).isProbablePrime(), "\(prime) là số nguyên tố")
        }
        // Gồm số Carmichael (561, 41041, 825265) và 2^61 - 1 nhân 3: những hợp số hay qua mặt kiểm tra Fermat.
        for composite: UInt64 in [0, 1, 4, 100, 561, 41041, 825_265, 2_147_483_647 * 3, 3_215_031_751] {
            #expect(try !BigUInt(composite).isProbablePrime(), "\(composite) là hợp số")
        }
        #expect(try KnownDHGroups.modp4096.shiftedRight(by: 4095) == BigUInt(1))
    }

    @Test func credentialsThatDoNotFitAreRejected() throws {
        let long = String(repeating: "x", count: 64)
        #expect(throws: RFBError.credentialTooLong(field: "mật khẩu")) {
            try Authenticator.credentialBlock(for: RFBCredentials(username: "u", password: long))
        }
        #expect(throws: RFBError.credentialTooLong(field: "tên tài khoản")) {
            try Authenticator.credentialBlock(for: RFBCredentials(username: long, password: "p"))
        }
        // 63 byte là vừa khít (còn 1 byte cho NUL)
        let block = try Authenticator.credentialBlock(for: RFBCredentials(username: String(repeating: "u", count: 63), password: "p"))
        #expect(block.count == 128)
        #expect(block[63] == 0)
    }
}
