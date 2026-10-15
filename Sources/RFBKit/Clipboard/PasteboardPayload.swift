import Foundation

/// One representation of the clipboard contents (the same text can come as UTF-8, UTF-16, MacRoman...).
public struct PasteboardRepresentation: Equatable, Sendable {
    public struct Attribute: Equatable, Sendable {
        public var key: String
        public var value: String

        public init(key: String, value: String) {
            self.key = key
            self.value = value
        }
    }

    /// Uniform Type Identifier, for example `public.utf8-plain-text`.
    public var uti: String
    /// The 32-bit field after the UTI. Apple's server always sends 0; kept as-is so it can be re-encoded exactly.
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

/// Clipboard contents in Apple's format (after decompression), all 32-bit big-endian integers:
///
/// ```
/// u32  number of representations
/// each representation:
///     u32 length, UTI                    (for example "public.utf8-plain-text")
///     u32 flags                          (always 0 when observed)
///     u32 number of attribute pairs
///     each pair: u32 length, key; u32 length, value
///     u32 length, data
/// ```
///
/// Derived from real `screensharingd` payloads (see `docs/protocol-notes.md`). **[QS]** observed; all other fields not seen.
public struct PasteboardPayload: Equatable, Sendable {
    /// Cap so corrupt or malicious data cannot force the client into an infinite loop or absurd allocation.
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

    /// Builds from a string, in the same mold as Apple's server sends: UTF-8 and big-endian UTF-16.
    /// Does not send the MacRoman variant: it loses characters it cannot represent (đ, ệ...) that the other two already cover.
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

    /// Best text available in the clipboard: UTF-8, then UTF-16, then MacRoman. `nil` if there is no text form.
    public var text: String? {
        func data(_ uti: String) -> Data? { representations.first { $0.uti == uti }?.data }
        if let bytes = data(Self.utf8Text), let text = String(data: bytes, encoding: .utf8) { return text }
        if let bytes = data(Self.utf16Text) {
            // Apple's server sends big-endian without a BOM. If there is a BOM, respect it.
            if bytes.starts(with: [0xFF, 0xFE]) || bytes.starts(with: [0xFE, 0xFF]) {
                if let text = String(data: bytes, encoding: .utf16) { return text }
            } else if let text = String(data: bytes, encoding: .utf16BigEndian) {
                return text
            }
        }
        if let bytes = data(Self.macRomanText), let text = String(data: bytes, encoding: .macOSRoman) { return text }
        return nil
    }

    // MARK: - Encoding

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

    // MARK: - Decoding

    /// Parses decompressed data. Every length is checked against what remains, so truncated or forged data
    /// produces an error rather than crashing the app or allocating at random.
    public init(serialized data: Data) throws {
        var reader = Reader(data)
        let count = Int(try reader.u32())
        guard count <= Self.maxRepresentations else { throw RFBError.malformed("clipboard has \(count) representations") }

        var result: [PasteboardRepresentation] = []
        for _ in 0..<count {
            let uti = try reader.string(maxBytes: Self.maxStringBytes)
            let flags = try reader.u32()
            let pairCount = Int(try reader.u32())
            guard pairCount <= Self.maxAttributes else { throw RFBError.malformed("clipboard has \(pairCount) attributes") }
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
            guard data.endIndex - offset >= 4 else { throw RFBError.malformed("clipboard is truncated") }
            defer { offset += 4 }
            return data[offset..<offset + 4].reduce(0) { ($0 << 8) | UInt32($1) }
        }

        mutating func block(maxBytes: Int) throws -> Data {
            let length = Int(try u32())
            guard length <= maxBytes, length <= data.endIndex - offset else {
                throw RFBError.malformed("clipboard declares length \(length) exceeding the remainder")
            }
            defer { offset += length }
            return data[offset..<offset + length]
        }

        mutating func string(maxBytes: Int) throws -> String {
            let bytes = try block(maxBytes: maxBytes)
            guard let text = String(data: bytes, encoding: .utf8) else { throw RFBError.malformed("clipboard string is not UTF-8") }
            return text
        }
    }
}
