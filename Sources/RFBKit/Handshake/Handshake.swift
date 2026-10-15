import Foundation

/// Kết quả của bước chào hỏi: phiên bản và danh sách security type server cho phép.
public struct ServerHello: Equatable, Sendable {
    public let serverVersion: RFBVersion
    public let negotiatedVersion: RFBVersion
    public let securityTypes: [RFBSecurityType]
}

public enum Handshake {
    /// Giới hạn độ dài lý do từ chối, để server lỗi không bắt ta cấp phát bộ nhớ vô hạn.
    private static let maxReasonLength = 4096

    /// Chạy handshake tới hết bước liệt kê security type.
    ///
    /// Hàm **không** chọn security type nào và không xác thực. Dùng để khám phá
    /// server hỗ trợ gì mà không cần mật khẩu.
    public static func readServerHello(over stream: some ByteStream) async throws -> ServerHello {
        let server = try RFBVersion(parsing: try await stream.read(exactly: 12))
        let negotiated = try server.negotiated()
        try await stream.write(Data(negotiated.wireString.utf8))

        let types: [RFBSecurityType]
        if negotiated == .v3_3 {
            // 3.3: server tự chọn và gửi một số 32-bit; 0 nghĩa là từ chối.
            let raw = try await stream.read(exactly: 4)
            let value = raw.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
            if value == 0 { throw RFBError.serverRejected(reason: try await readReason(from: stream)) }
            guard let byte = UInt8(exactly: value) else {
                throw RFBError.malformed("security type 3.3 vượt phạm vi: \(value)")
            }
            types = [RFBSecurityType(rawValue: byte)]
        } else {
            // 3.7 trở lên: 1 byte đếm, theo sau là từng byte type; đếm 0 nghĩa là từ chối.
            guard let count = try await stream.read(exactly: 1).first else { throw RFBError.connectionClosed }
            if count == 0 { throw RFBError.serverRejected(reason: try await readReason(from: stream)) }
            let bytes = try await stream.read(exactly: Int(count))
            types = bytes.map { RFBSecurityType(rawValue: $0) }
        }
        return ServerHello(serverVersion: server, negotiatedVersion: negotiated, securityTypes: types)
    }

    /// Gửi lựa chọn security type (1 byte, áp dụng cho 3.7 trở lên).
    ///
    /// Sau lời gọi này server bắt đầu bước xác thực riêng của type đó. Hàm chỉ chọn,
    /// không gửi thông tin đăng nhập.
    public static func selectSecurityType(_ type: RFBSecurityType, over stream: some ByteStream) async throws {
        try await stream.write(Data([type.rawValue]))
    }

    /// Như trên nhưng theo phiên bản đã thương lượng: ở RFB 3.3 server tự chọn kiểu và client **không** gửi byte nào
    /// (gửi thừa làm lệch một byte của bước xác thực).
    public static func selectSecurityType(_ type: RFBSecurityType, version: RFBVersion, over stream: some ByteStream) async throws {
        guard version != .v3_3 else { return }
        try await selectSecurityType(type, over: stream)
    }

    /// Đọc chuỗi lý do: 4 byte độ dài (big-endian) rồi nội dung UTF-8.
    static func readReason(from stream: some ByteStream) async throws -> String {
        let lengthBytes = try await stream.read(exactly: 4)
        let length = Int(lengthBytes.reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
        guard length <= maxReasonLength else { throw RFBError.malformed("lý do từ chối dài \(length) byte") }
        return String(decoding: try await stream.read(exactly: length), as: UTF8.self)
    }
}
