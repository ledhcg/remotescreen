import Foundation

/// Một lần chuyển clipboard theo giao thức riêng của Apple: message loại 31, **cùng một định dạng hai chiều**.
///
/// ```
/// u8  31
/// u8  0
/// u8  cờ (bit 0 = "promise")         // quan sát 0
/// u8  0
/// u32 mã                             // server lặp lại mã của ClipboardRequest (loại 11)
/// u32 kích thước sau giải nén
/// u32 kích thước dữ liệu nén
/// ... dữ liệu nén (zlib) của `PasteboardPayload`
/// ```
///
/// Suy ra từ disassembly `screensharingd` và xác nhận bằng một lần hỏi-đáp thật: gửi `0b 00 00 00 de ad be ef`,
/// nhận lại `1f 00 00 00 de ad be ef 00 00 01 e4 00 00 01 08 78 da ...`. **[QS]**
public struct ClipboardTransfer: Equatable, Sendable {
    public static let messageType: UInt8 = 31
    /// Server chấp nhận tới 100 MiB mỗi chiều. Client giữ trần thấp hơn nhiều: văn bản thực tế nhỏ, và dữ liệu lớn
    /// hơn chỉ tốn bộ nhớ trên điện thoại.
    public static let maxCompressed = 8 << 20
    public static let maxUncompressed = 16 << 20

    public var token: UInt32
    public var flags: UInt8
    public var uncompressedSize: UInt32
    public var compressed: Data

    public init(token: UInt32, flags: UInt8 = 0, uncompressedSize: UInt32, compressed: Data) {
        self.token = token
        self.flags = flags
        self.uncompressedSize = uncompressedSize
        self.compressed = compressed
    }

    /// Dựng message gửi một chuỗi lên Mac.
    public init(text: String, token: UInt32 = 0) throws {
        let raw = PasteboardPayload(text: text).serialized()
        guard raw.count <= Self.maxUncompressed else { throw RFBError.malformed("clipboard dài \(raw.count) byte") }
        let compressed = try ClipboardZlib.deflate(raw)
        guard compressed.count <= Self.maxCompressed else { throw RFBError.malformed("clipboard nén còn \(compressed.count) byte") }
        self.init(token: token, uncompressedSize: UInt32(raw.count), compressed: compressed)
    }

    /// Giải nén và phân tích. Kích thước khai báo là trần: dữ liệu giải nén ra lớn hơn nó là lỗi, và phải khớp đúng.
    public func decodePayload() throws -> PasteboardPayload {
        guard uncompressedSize <= UInt32(Self.maxUncompressed) else { throw RFBError.malformed("clipboard khai \(uncompressedSize) byte") }
        let raw = try ClipboardZlib.inflate(compressed, maxOutput: Int(uncompressedSize))
        guard raw.count == Int(uncompressedSize) else {
            throw RFBError.malformed("clipboard giải nén ra \(raw.count) byte, khai báo \(uncompressedSize)")
        }
        return try PasteboardPayload(serialized: raw)
    }

    public var wireBytes: Data {
        var data = Data([Self.messageType, 0, flags, 0])
        data.appendBigEndian(token)
        data.appendBigEndian(uncompressedSize)
        data.appendBigEndian(UInt32(compressed.count))
        data.append(compressed)
        return data
    }
}
