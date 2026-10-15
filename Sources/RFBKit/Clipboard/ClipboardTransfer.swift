import Foundation

/// One clipboard transfer in Apple's own protocol: message type 31, **the same format in both directions**.
///
/// ```
/// u8  31
/// u8  0
/// u8  flags (bit 0 = "promise")       // observed 0
/// u8  0
/// u32 token                           // the server repeats the token of ClipboardRequest (type 11)
/// u32 uncompressed size
/// u32 compressed data size
/// ... compressed (zlib) data of the `PasteboardPayload`
/// ```
///
/// Derived from disassembling `screensharingd` and confirmed by one real request-reply: sending `0b 00 00 00 de ad be ef`,
/// receiving `1f 00 00 00 de ad be ef 00 00 01 e4 00 00 01 08 78 da ...`. **[QS]**
public struct ClipboardTransfer: Equatable, Sendable {
    public static let messageType: UInt8 = 31
    /// The server accepts up to 100 MiB in each direction. The client keeps a much lower cap: real text is small, and larger data
    /// only costs memory on the phone.
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

    /// Builds a message that sends a string to the Mac.
    public init(text: String, token: UInt32 = 0) throws {
        let raw = PasteboardPayload(text: text).serialized()
        guard raw.count <= Self.maxUncompressed else { throw RFBError.malformed("clipboard is \(raw.count) bytes long") }
        let compressed = try ClipboardZlib.deflate(raw)
        guard compressed.count <= Self.maxCompressed else { throw RFBError.malformed("compressed clipboard is still \(compressed.count) bytes") }
        self.init(token: token, uncompressedSize: UInt32(raw.count), compressed: compressed)
    }

    /// Decompresses and parses. The declared size is a cap: decompressed data larger than it is an error, and it must match exactly.
    public func decodePayload() throws -> PasteboardPayload {
        guard uncompressedSize <= UInt32(Self.maxUncompressed) else { throw RFBError.malformed("clipboard khai \(uncompressedSize) byte") }
        let raw = try ClipboardZlib.inflate(compressed, maxOutput: Int(uncompressedSize))
        guard raw.count == Int(uncompressedSize) else {
            throw RFBError.malformed("clipboard decompressed to \(raw.count) bytes, declared \(uncompressedSize)")
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
