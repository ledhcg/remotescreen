import Foundation
import RFBCrypto

public struct RFBCredentials: Sendable, Equatable {
    /// Tên tài khoản. Chỉ dùng cho Apple Remote Desktop (type 30); VNC Authentication bỏ qua.
    public var username: String
    public var password: String

    public init(username: String = "", password: String = "") {
        self.username = username
        self.password = password
    }
}

/// Thực hiện bước xác thực sau khi client đã chọn security type.
///
/// Hỗ trợ: None (1), VNC Authentication (2), Apple Remote Desktop (30).
/// Các type khác của Apple (31 đến 36) chưa được hiểu, xem `docs/protocol-notes.md`.
public enum Authenticator {
    /// Số nguyên tố DH nhỏ hơn mức này bị từ chối, để server (hoặc kẻ chen giữa) không ép hạ xuống nhóm yếu.
    /// 1024-bit không còn được coi là đủ an toàn; macOS dùng 4096-bit.
    static let minimumPrimeBits = 2048
    /// Số vòng Miller-Rabin cho nhóm lạ (sai số tối đa 4^-6). Nhóm đã biết (`KnownDHGroups`) không cần kiểm tra.
    static let primalityRounds = 6
    /// `p - 1` chia hết cho tối đa 2^32. Số nguyên tố DH thật gần như luôn có `p - 1 = 2q` hoặc `2·số lẻ`; cấu trúc quá lệch
    /// vừa không dùng cho DH, vừa khiến Miller-Rabin phải bình phương rất nhiều lần.
    static let maximumTwoPowerInPMinusOne = 32
    /// Server của Apple dùng 4096-bit, tức 512 byte. Trần 1024 byte (8192-bit) chặn tham số vô lý.
    static let maximumKeyLength = 1024
    static let ardFieldLength = 64

    public static func authenticate(
        type: RFBSecurityType,
        version: RFBVersion,
        credentials: RFBCredentials,
        over stream: some ByteStream,
        privateExponentBits: Int = 512
    ) async throws {
        switch type {
        case .noAuthentication:
            break
        case .vncAuthentication:
            try await authenticateVNC(password: credentials.password, over: stream)
        case .appleRemoteDesktop:
            try await authenticateARD(
                credentials: credentials, privateExponentBits: privateExponentBits, over: stream
            )
        default:
            throw RFBError.unsupportedSecurityType(type)
        }

        // Từ 3.8 server luôn gửi SecurityResult. Trước đó, type None không có bước này.
        if type != .noAuthentication || version >= .v3_8 {
            try await readSecurityResult(version: version, over: stream)
        }
    }

    // MARK: - VNC Authentication (type 2)

    private static func authenticateVNC(password: String, over stream: some ByteStream) async throws {
        let challenge = try await stream.read(exactly: 16)
        try await stream.write(try VNCAuthentication.response(to: challenge, password: password))
    }

    // MARK: - Apple Remote Desktop (type 30)

    /// Luồng đã quan sát trên `screensharingd` (macOS 27), xem `docs/protocol-notes.md` mục 3:
    ///
    ///     server → client: generator (2) | độ dài khóa N (2) | số nguyên tố p (N) | khóa công khai B (N)
    ///     client → server: dữ liệu đăng nhập đã mã hóa (128) | khóa công khai A (N)
    ///
    /// Khóa AES = MD5(bí mật chung) và bố cục 64+64 byte của khối đăng nhập đã được xác nhận bằng đăng nhập thật vào
    /// `screensharingd` (macOS 27) với nhóm 4096-bit. ARD không xác thực server, nên kiểm tra tham số ở đây chỉ chặn
    /// các tham số yếu; kẻ chen giữa hoàn toàn vẫn đóng giả được server. Vì vậy chỉ dùng trong mạng tin cậy.
    private static func authenticateARD(
        credentials: RFBCredentials,
        privateExponentBits: Int,
        over stream: some ByteStream
    ) async throws {
        let generatorValue = try await stream.readUInt16()
        let keyLength = Int(try await stream.readUInt16())
        guard keyLength * 8 >= minimumPrimeBits, keyLength <= maximumKeyLength else {
            throw RFBError.invalidKeyExchange("độ dài khóa \(keyLength) byte nằm ngoài khoảng chấp nhận")
        }

        let prime = BigUInt(bigEndianBytes: try await stream.read(exactly: keyLength))
        let serverPublic = BigUInt(bigEndianBytes: try await stream.read(exactly: keyLength))

        guard prime.isOdd, prime.bitWidth >= minimumPrimeBits else {
            throw RFBError.invalidKeyExchange("số nguyên tố p không hợp lệ")
        }
        guard try isAcceptableGroup(prime) else {
            throw RFBError.invalidKeyExchange("số nguyên tố p không phải số nguyên tố, hoặc cấu trúc không dùng được cho DH")
        }
        guard generatorValue >= 2 else {
            throw RFBError.invalidKeyExchange("generator \(generatorValue) không hợp lệ")
        }
        let one = BigUInt(1)
        guard serverPublic > one, serverPublic < prime - one else {
            throw RFBError.invalidKeyExchange("khóa công khai của server nằm ngoài khoảng (1, p-1)")
        }

        let secret = BigUInt(bigEndianBytes: try SecureRandom.bytes((privateExponentBits + 7) / 8))
        guard secret.bitWidth > 1 else { throw RFBError.invalidKeyExchange("khóa riêng sinh ra quá nhỏ") }

        let clientPublic = BigUInt(UInt64(generatorValue)).modPow(secret, modulus: prime)
        let shared = serverPublic.modPow(secret, modulus: prime)
        let aesKey = MD5.hash(Data(shared.bigEndianBytes(paddedTo: keyLength)))

        let encrypted = try AES128ECB.encrypt(try credentialBlock(for: credentials), key: aesKey)
        try await stream.write(encrypted + Data(clientPublic.bigEndianBytes(paddedTo: keyLength)))
    }

    /// `p` là nhóm đã biết, hoặc là số nguyên tố (xác suất) với cấu trúc dùng được. Chặn server gửi hợp số "mịn" để tính được
    /// bí mật chung, rồi giải mã khối đăng nhập.
    static func isAcceptableGroup(_ prime: BigUInt) throws -> Bool {
        if prime == KnownDHGroups.modp4096 { return true }
        var twoPower = 0
        while !(prime - BigUInt(1)).bit(at: twoPower) { twoPower += 1 }
        guard twoPower <= maximumTwoPowerInPMinusOne else { return false }
        return try prime.isProbablePrime(rounds: primalityRounds)
    }

    /// Khối 128 byte: tên (64) rồi mật khẩu (64), mỗi trường kết thúc bằng NUL, phần còn lại đệm ngẫu nhiên.
    static func credentialBlock(for credentials: RFBCredentials) throws -> Data {
        var block = try SecureRandom.bytes(2 * ardFieldLength)
        for (offset, name, text) in [(0, "tên tài khoản", credentials.username), (ardFieldLength, "mật khẩu", credentials.password)] {
            let bytes = Array(text.utf8)
            guard bytes.count < ardFieldLength else { throw RFBError.credentialTooLong(field: name) }
            block.replaceSubrange(offset..<offset + bytes.count, with: bytes)
            block[offset + bytes.count] = 0
        }
        return Data(block)
    }

    // MARK: - SecurityResult

    /// 4 byte: 0 là thành công. Từ 3.8, nếu thất bại thì kèm chuỗi lý do.
    private static func readSecurityResult(version: RFBVersion, over stream: some ByteStream) async throws {
        guard try await stream.readUInt32() != 0 else { return }
        let reason = version >= .v3_8 ? try await Handshake.readReason(from: stream) : "xác thực thất bại"
        throw RFBError.authenticationFailed(reason: reason)
    }
}
