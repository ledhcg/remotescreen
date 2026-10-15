import Foundation

/// Một biểu diễn của nội dung clipboard (cùng một văn bản có thể có UTF-8, UTF-16, MacRoman...).
public struct PasteboardRepresentation: Equatable, Sendable {
    public struct Attribute: Equatable, Sendable {
        public var key: String
        public var value: String

        public init(key: String, value: String) {
            self.key = key
            self.value = value
        }
    }

    /// Uniform Type Identifier, ví dụ `public.utf8-plain-text`.
    public var uti: String
    /// Trường 32-bit đứng sau UTI. Server Apple luôn gửi 0; giữ nguyên để mã hóa lại được đúng.
    public var flags: UInt32
    public var attributes: [Attribute]
    public var data: Data

    public init(uti: String, flags: UInt32 = 0, attributes: [Attribute] = [], data: Data) {
        self.uti = uti
        self.flags = flags
        self.attributes = attributes
        self.data = data
    }
}

/// Nội dung clipboard theo định dạng của Apple (sau khi giải nén), toàn bộ số nguyên 32-bit big-endian:
///
/// ```
/// u32  số biểu diễn
/// mỗi biểu diễn:
///     u32 độ dài, UTI                    (ví dụ "public.utf8-plain-text")
///     u32 flags                          (luôn 0 khi quan sát)
///     u32 số cặp thuộc tính
///     mỗi cặp: u32 độ dài, khóa; u32 độ dài, giá trị
///     u32 độ dài, dữ liệu
/// ```
///
/// Suy ra từ payload thật của `screensharingd` (xem `docs/protocol-notes.md`). **[QS]** quan sát; mọi trường khác chưa thấy.
public struct PasteboardPayload: Equatable, Sendable {
    /// Trần để dữ liệu hỏng hay độc hại không ép client lặp vô hạn hay cấp phát vô lý.
    static let maxRepresentations = 64
    static let maxAttributes = 64
    static let maxStringBytes = 4096

    public static let utf8Text = "public.utf8-plain-text"
    public static let utf16Text = "public.utf16-plain-text"
    public static let macRomanText = "com.apple.traditional-mac-plain-text"

    public var representations: [PasteboardRepresentation]

    public init(representations: [PasteboardRepresentation]) {
        self.representations = representations
    }

    /// Dựng từ một chuỗi, theo cùng khuôn server Apple gửi: UTF-8 và UTF-16 big-endian.
    /// Không gửi bản MacRoman: nó mất ký tự không biểu diễn được (đ, ệ...) mà hai bản kia đã đủ.
    public init(text: String) {
        representations = [
            PasteboardRepresentation(
                uti: Self.utf8Text,
                attributes: [
                    .init(key: "com.apple.ostype", value: "utf8"),
                    .init(key: "com.apple.nspboard-type", value: "NSStringPboardType"),
                    .init(key: "public.mime-type", value: "text/plain;charset=utf-8"),
                ],
                data: Data(text.utf8)
            ),
            PasteboardRepresentation(
                uti: Self.utf16Text,
                attributes: [
                    .init(key: "com.apple.ostype", value: "utxt"),
                    .init(key: "public.mime-type", value: "text/plain;charset=utf-16"),
                ],
                data: text.data(using: .utf16BigEndian) ?? Data()
            ),
        ]
    }

    /// Văn bản tốt nhất có trong clipboard: UTF-8, rồi UTF-16, rồi MacRoman. `nil` nếu không có dạng văn bản nào.
    public var text: String? {
        func data(_ uti: String) -> Data? { representations.first { $0.uti == uti }?.data }
        if let bytes = data(Self.utf8Text), let text = String(data: bytes, encoding: .utf8) { return text }
        if let bytes = data(Self.utf16Text) {
            // Server Apple gửi big-endian không BOM. Nếu có BOM thì tôn trọng nó.
            if bytes.starts(with: [0xFF, 0xFE]) || bytes.starts(with: [0xFE, 0xFF]) {
                if let text = String(data: bytes, encoding: .utf16) { return text }
            } else if let text = String(data: bytes, encoding: .utf16BigEndian) {
                return text
            }
        }
        if let bytes = data(Self.macRomanText), let text = String(data: bytes, encoding: .macOSRoman) { return text }
        return nil
    }

    // MARK: - Mã hóa

    public func serialized() -> Data {
        var data = Data()
        data.appendBigEndian(UInt32(representations.count))
        for representation in representations {
            Self.appendBlock(Data(representation.uti.utf8), to: &data)
            data.appendBigEndian(representation.flags)
            data.appendBigEndian(UInt32(representation.attributes.count))
            for attribute in representation.attributes {
                Self.appendBlock(Data(attribute.key.utf8), to: &data)
                Self.appendBlock(Data(attribute.value.utf8), to: &data)
            }
            Self.appendBlock(representation.data, to: &data)
        }
        return data
    }

    private static func appendBlock(_ block: Data, to data: inout Data) {
        data.appendBigEndian(UInt32(block.count))
        data.append(block)
    }

    // MARK: - Giải mã

    /// Phân tích dữ liệu đã giải nén. Mọi độ dài đều được kiểm tra với phần còn lại, nên dữ liệu cắt cụt hay giả mạo
    /// cho lỗi chứ không làm app sập hay cấp phát bừa.
    public init(serialized data: Data) throws {
        var reader = Reader(data)
        let count = Int(try reader.u32())
        guard count <= Self.maxRepresentations else { throw RFBError.malformed("clipboard có \(count) biểu diễn") }

        var result: [PasteboardRepresentation] = []
        for _ in 0..<count {
            let uti = try reader.string(maxBytes: Self.maxStringBytes)
            let flags = try reader.u32()
            let pairCount = Int(try reader.u32())
            guard pairCount <= Self.maxAttributes else { throw RFBError.malformed("clipboard có \(pairCount) thuộc tính") }
            var attributes: [PasteboardRepresentation.Attribute] = []
            for _ in 0..<pairCount {
                attributes.append(.init(
                    key: try reader.string(maxBytes: Self.maxStringBytes),
                    value: try reader.string(maxBytes: Self.maxStringBytes)
                ))
            }
            let payload = try reader.block(maxBytes: Int.max)
            result.append(PasteboardRepresentation(uti: uti, flags: flags, attributes: attributes, data: payload))
        }
        self.init(representations: result)
    }

    private struct Reader {
        private let data: Data
        private var offset: Int

        init(_ data: Data) {
            self.data = data
            offset = data.startIndex
        }

        mutating func u32() throws -> UInt32 {
            guard data.endIndex - offset >= 4 else { throw RFBError.malformed("clipboard bị cắt cụt") }
            defer { offset += 4 }
            return data[offset..<offset + 4].reduce(0) { ($0 << 8) | UInt32($1) }
        }

        mutating func block(maxBytes: Int) throws -> Data {
            let length = Int(try u32())
            guard length <= maxBytes, length <= data.endIndex - offset else {
                throw RFBError.malformed("clipboard khai độ dài \(length) vượt phần còn lại")
            }
            defer { offset += length }
            return data[offset..<offset + length]
        }

        mutating func string(maxBytes: Int) throws -> String {
            let bytes = try block(maxBytes: maxBytes)
            guard let text = String(data: bytes, encoding: .utf8) else { throw RFBError.malformed("chuỗi clipboard không phải UTF-8") }
            return text
        }
    }
}
