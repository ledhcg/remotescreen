import Foundation

/// Luồng byte hai chiều mà giao thức RFB chạy trên đó.
///
/// Tách khỏi Network.framework để handshake và decoder test được bằng dữ liệu
/// trong bộ nhớ, không cần mạng hay server thật.
public protocol ByteStream: Sendable {
    /// Đọc đúng `count` byte. Ném `RFBError.connectionClosed` nếu luồng đóng sớm.
    func read(exactly count: Int) async throws -> Data
    /// Đọc những gì đang có, tối thiểu 1 và tối đa `maxCount` byte. Dùng khi chưa biết
    /// độ dài phản hồi (khám phá giao thức). Ném `RFBError.connectionClosed` nếu luồng đóng.
    func readSome(maxCount: Int) async throws -> Data
    func write(_ data: Data) async throws
    func close() async
}

public enum RFBError: Error, Equatable, Sendable {
    case connectionClosed
    case invalidVersionString(String)
    case unsupportedVersion(RFBVersion)
    case serverRejected(reason: String)
    case malformed(String)
    case unsupportedSecurityType(RFBSecurityType)
    case authenticationFailed(reason: String)
    case invalidKeyExchange(String)
    case credentialTooLong(field: String)
    /// Server gửi encoding mà client chưa giải mã được. Không thể bỏ qua vì không biết độ dài dữ liệu.
    case unsupportedEncoding(RFBEncoding)
    /// Server không cung cấp security type nào mà client hỗ trợ và có đủ thông tin đăng nhập để dùng.
    case noCompatibleSecurityType(offered: [RFBSecurityType])
    case timedOut
}

extension ByteStream {
    public func readUInt8() async throws -> UInt8 {
        guard let byte = try await read(exactly: 1).first else { throw RFBError.connectionClosed }
        return byte
    }

    public func readUInt16() async throws -> UInt16 {
        try await read(exactly: 2).reduce(UInt16(0)) { $0 << 8 | UInt16($1) }
    }

    public func readUInt32() async throws -> UInt32 {
        try await read(exactly: 4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
    }
}
