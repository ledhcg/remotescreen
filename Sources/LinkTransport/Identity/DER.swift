import Foundation

/// Minimal DER (ITU-T X.690) writer used to hand-build X.509 certificates. Only what Screon needs.
enum DER {
    static let booleanTag: UInt8 = 0x01
    static let integerTag: UInt8 = 0x02
    static let bitStringTag: UInt8 = 0x03
    static let octetStringTag: UInt8 = 0x04
    static let oidTag: UInt8 = 0x06
    static let utf8StringTag: UInt8 = 0x0C
    static let utcTimeTag: UInt8 = 0x17
    static let generalizedTimeTag: UInt8 = 0x18
    static let sequenceTag: UInt8 = 0x30
    static let setTag: UInt8 = 0x31

    static func length(_ n: Int) -> [UInt8] {
        precondition(n >= 0)
        if n < 0x80 { return [UInt8(n)] }
        var bytes: [UInt8] = []
        var v = n
        while v > 0 { bytes.insert(UInt8(v & 0xFF), at: 0); v >>= 8 }
        return [0x80 | UInt8(bytes.count)] + bytes
    }

    static func tlv(_ tag: UInt8, _ content: [UInt8]) -> [UInt8] {
        [tag] + length(content.count) + content
    }

    static func sequence(_ parts: [UInt8]...) -> [UInt8] { tlv(sequenceTag, parts.flatMap { $0 }) }
    static func set(_ parts: [UInt8]...) -> [UInt8] { tlv(setTag, parts.flatMap { $0 }) }

    /// Constructed, context-specific, explicit tag `[n]` (n < 31).
    static func explicit(_ n: UInt8, _ content: [UInt8]) -> [UInt8] { tlv(0xA0 | n, content) }

    static func boolean(_ value: Bool) -> [UInt8] { tlv(booleanTag, [value ? 0xFF : 0x00]) }

    /// Non-negative INTEGER from big-endian magnitude bytes (minimal encoding).
    static func integer(magnitude bytes: [UInt8]) -> [UInt8] {
        var b = Array(bytes.drop(while: { $0 == 0 }))
        if b.isEmpty { b = [0] }
        if b[0] & 0x80 != 0 { b.insert(0, at: 0) }
        return tlv(integerTag, b)
    }

    static func integer(_ value: Int) -> [UInt8] {
        precondition(value >= 0)
        var bytes: [UInt8] = []
        var v = value
        while v > 0 { bytes.insert(UInt8(v & 0xFF), at: 0); v >>= 8 }
        return integer(magnitude: bytes)
    }

    static func oid(_ arcs: [UInt64]) -> [UInt8] {
        precondition(arcs.count >= 2 && arcs[0] <= 2)
        var content: [UInt8] = [UInt8(arcs[0] * 40 + arcs[1])]
        for arc in arcs.dropFirst(2) {
            var chunk: [UInt8] = [UInt8(arc & 0x7F)]
            var v = arc >> 7
            while v > 0 { chunk.insert(UInt8(v & 0x7F) | 0x80, at: 0); v >>= 7 }
            content += chunk
        }
        return tlv(oidTag, content)
    }

    static func octetString(_ bytes: [UInt8]) -> [UInt8] { tlv(octetStringTag, bytes) }
    static func utf8String(_ s: String) -> [UInt8] { tlv(utf8StringTag, Array(s.utf8)) }

    /// BIT STRING with `unusedBits` trailing padding bits.
    static func bitString(_ bytes: [UInt8], unusedBits: UInt8 = 0) -> [UInt8] {
        tlv(bitStringTag, [unusedBits] + bytes)
    }

    /// UTCTime for 1950...2049, GeneralizedTime otherwise.
    static func time(_ date: Date) -> [UInt8] {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year = c.year ?? 1970
        func p(_ v: Int?, _ w: Int) -> String {
            let s = String(v ?? 0)
            return String(repeating: "0", count: max(0, w - s.count)) + s
        }
        let rest = p(c.month, 2) + p(c.day, 2) + p(c.hour, 2) + p(c.minute, 2) + p(c.second, 2) + "Z"
        if (1950...2049).contains(year) {
            return tlv(utcTimeTag, Array((p(year % 100, 2) + rest).utf8))
        }
        return tlv(generalizedTimeTag, Array((p(year, 4) + rest).utf8))
    }
}

enum DERError: Error, Equatable {
    case malformed(String)
}

/// Small bounded DER reader: single-byte tags, definite lengths, never reads past its buffer.
struct DERReader {
    struct Element {
        let tag: UInt8
        /// Range of the content within the reader's buffer.
        let content: Range<Int>
        /// Range of the whole TLV.
        let full: Range<Int>
    }

    static let maxInputBytes = 16 * 1024

    let bytes: [UInt8]
    private(set) var offset: Int
    let end: Int

    init(_ data: Data) throws {
        guard data.count <= Self.maxInputBytes else { throw DERError.malformed("input too large") }
        bytes = [UInt8](data)
        offset = 0
        end = bytes.count
    }

    init(bytes: [UInt8], range: Range<Int>) {
        self.bytes = bytes
        offset = range.lowerBound
        end = range.upperBound
    }

    var isAtEnd: Bool { offset >= end }

    mutating func next() throws -> Element {
        let start = offset
        guard offset < end else { throw DERError.malformed("truncated") }
        let tag = bytes[offset]
        guard tag & 0x1F != 0x1F else { throw DERError.malformed("high tag numbers unsupported") }
        offset += 1
        guard offset < end else { throw DERError.malformed("truncated length") }
        let first = bytes[offset]
        offset += 1
        var len = 0
        if first < 0x80 {
            len = Int(first)
        } else {
            let n = Int(first & 0x7F)
            guard n >= 1, n <= 3 else { throw DERError.malformed("unsupported length form") }
            guard end - offset >= n else { throw DERError.malformed("truncated length") }
            guard bytes[offset] != 0 else { throw DERError.malformed("non-minimal length") }
            for _ in 0..<n { len = (len << 8) | Int(bytes[offset]); offset += 1 }
            guard len >= 0x80 else { throw DERError.malformed("non-minimal length") }
        }
        guard len <= end - offset else { throw DERError.malformed("length exceeds input") }
        let content = offset..<(offset + len)
        offset += len
        return Element(tag: tag, content: content, full: start..<offset)
    }

    mutating func next(expecting tag: UInt8) throws -> Element {
        let e = try next()
        guard e.tag == tag else { throw DERError.malformed("unexpected tag") }
        return e
    }

    func reader(for e: Element) -> DERReader { DERReader(bytes: bytes, range: e.content) }
}
