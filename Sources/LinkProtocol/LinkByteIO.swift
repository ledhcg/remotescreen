import Foundation

/// Bounded little-endian reader over one message payload. Every read checks the remaining bytes, every string, blob and
/// count is compared with a cap before it is sliced or reserved, and nothing here traps.
public struct LinkReader: Sendable {
    private let bytes: [UInt8]
    private var offset = 0

    public init(_ bytes: [UInt8]) { self.bytes = bytes }

    public var remaining: Int { bytes.count - offset }
    public var isAtEnd: Bool { remaining == 0 }

    private mutating func take(_ count: Int, _ what: String) throws -> Range<Int> {
        guard count >= 0, count <= remaining else { throw LinkError.malformed("truncated \(what)") }
        defer { offset += count }
        return offset..<(offset + count)
    }

    public mutating func u8(_ what: String = "u8") throws -> UInt8 { bytes[try take(1, what).lowerBound] }

    public mutating func u16(_ what: String = "u16") throws -> UInt16 {
        let r = try take(2, what)
        return UInt16(bytes[r.lowerBound]) | UInt16(bytes[r.lowerBound + 1]) << 8
    }

    public mutating func u32(_ what: String = "u32") throws -> UInt32 {
        let r = try take(4, what)
        var value: UInt32 = 0
        for i in 0..<4 { value |= UInt32(bytes[r.lowerBound + i]) << (8 * UInt32(i)) }
        return value
    }

    public mutating func u64(_ what: String = "u64") throws -> UInt64 {
        let r = try take(8, what)
        var value: UInt64 = 0
        for i in 0..<8 { value |= UInt64(bytes[r.lowerBound + i]) << (8 * UInt64(i)) }
        return value
    }

    public mutating func i16(_ what: String = "i16") throws -> Int16 { Int16(bitPattern: try u16(what)) }
    public mutating func i32(_ what: String = "i32") throws -> Int32 { Int32(bitPattern: try u32(what)) }
    public mutating func i64(_ what: String = "i64") throws -> Int64 { Int64(bitPattern: try u64(what)) }

    /// A boolean that must be exactly 0 or 1.
    public mutating func bool(_ what: String = "bool") throws -> Bool {
        switch try u8(what) {
        case 0: return false
        case 1: return true
        default: throw LinkError.malformed("invalid boolean in \(what)")
        }
    }

    /// A finite `Float64`.
    public mutating func f64(_ what: String = "f64") throws -> Double {
        let value = Double(bitPattern: try u64(what))
        guard value.isFinite else { throw LinkError.malformed("non-finite number in \(what)") }
        return value
    }

    /// A finite `Float32`.
    public mutating func f32(_ what: String = "f32") throws -> Float {
        let value = Float(bitPattern: try u32(what))
        guard value.isFinite else { throw LinkError.malformed("non-finite number in \(what)") }
        return value
    }

    /// UTF-8 string with a `u16` byte length of at most `maxBytes`. Invalid UTF-8 is rejected.
    public mutating func string(maxBytes: Int, _ what: String) throws -> String {
        let length = Int(try u16(what))
        guard length <= maxBytes else { throw LinkError.limitExceeded("\(what) is \(length) bytes, limit \(maxBytes)") }
        let range = try take(length, what)
        guard let string = String(bytes: bytes[range], encoding: .utf8) else { throw LinkError.malformed("\(what) is not valid UTF-8") }
        return string
    }

    /// Blob with a `u32` length of at most `maxBytes`. The length is checked against the cap and the remaining bytes before slicing.
    public mutating func blob(maxBytes: Int, _ what: String) throws -> Data {
        let length = Int(try u32(what))
        guard length <= maxBytes else { throw LinkError.limitExceeded("\(what) is \(length) bytes, limit \(maxBytes)") }
        let range = try take(length, what)
        return Data(bytes[range])
    }

    /// Exactly `count` raw bytes.
    public mutating func fixed(_ count: Int, _ what: String) throws -> Data {
        Data(bytes[try take(count, what)])
    }

    public mutating func bytes32(_ what: String) throws -> LinkBytes32 {
        try LinkBytes32(try fixed(32, what))
    }

    /// An element count (`u16`) that is at most `max` and could fit in the remaining bytes at `minElementBytes` each.
    /// Call this before `reserveCapacity` or looping, so a lying count never allocates.
    public mutating func count(max: Int, minElementBytes: Int, _ what: String) throws -> Int {
        let n = Int(try u16(what))
        guard n <= max else { throw LinkError.limitExceeded("\(what) count \(n), limit \(max)") }
        guard n * minElementBytes <= remaining else { throw LinkError.malformed("\(what) count \(n) exceeds the payload") }
        return n
    }

    /// An enum stored as `u8`. Unknown raw values are malformed (see `LinkMessage` for the policy).
    public mutating func enumeration<E: RawRepresentable>(_ type: E.Type, _ what: String) throws -> E where E.RawValue == UInt8 {
        let raw = try u8(what)
        guard let value = E(rawValue: raw) else { throw LinkError.malformed("unknown \(what) \(raw)") }
        return value
    }

    /// A point that is finite and within `LinkLimits.maxCoordinate`.
    public mutating func point(_ what: String) throws -> LinkPoint {
        let point = LinkPoint(x: try f64(what), y: try f64(what))
        guard point.isValid else { throw LinkError.malformed("\(what) out of range") }
        return point
    }

    public mutating func size(_ what: String) throws -> LinkSize {
        let size = LinkSize(width: try f64(what), height: try f64(what))
        guard size.isValid else { throw LinkError.malformed("\(what) out of range") }
        return size
    }

    public mutating func rect(_ what: String) throws -> LinkRect {
        LinkRect(origin: try point(what), size: try size(what))
    }

    /// A scale factor in (0, `LinkLimits.maxScale`].
    public mutating func scale(_ what: String) throws -> Double {
        let value = try f64(what)
        guard value > 0, value <= LinkLimits.maxScale else { throw LinkError.malformed("\(what) out of range") }
        return value
    }

    /// A pixel dimension in 1...`LinkLimits.maxPixelDimension`.
    public mutating func pixelDimension(_ what: String) throws -> UInt32 {
        let value = try u32(what)
        guard value >= 1, value <= LinkLimits.maxPixelDimension else { throw LinkError.malformed("\(what) out of range") }
        return value
    }

    /// Fails if bytes are left over. Messages are strict: a new field means a new protocol version or a new message type.
    public func finish(_ what: String) throws {
        guard isAtEnd else { throw LinkError.malformed("\(remaining) trailing bytes in \(what)") }
    }
}

/// Little-endian writer, the mirror of `LinkReader`. Writing throws `LinkError.invalidValue`/`limitExceeded` instead of
/// producing something the peer would reject.
public struct LinkWriter: Sendable {
    public private(set) var bytes: [UInt8] = []

    public init(capacity: Int = 0) { bytes.reserveCapacity(capacity) }

    public mutating func u8(_ value: UInt8) { bytes.append(value) }
    public mutating func u16(_ value: UInt16) { bytes.append(UInt8(truncatingIfNeeded: value)); bytes.append(UInt8(truncatingIfNeeded: value >> 8)) }
    public mutating func u32(_ value: UInt32) { for i in 0..<4 { bytes.append(UInt8(truncatingIfNeeded: value >> (8 * UInt32(i)))) } }
    public mutating func u64(_ value: UInt64) { for i in 0..<8 { bytes.append(UInt8(truncatingIfNeeded: value >> (8 * UInt64(i)))) } }
    public mutating func i16(_ value: Int16) { u16(UInt16(bitPattern: value)) }
    public mutating func i32(_ value: Int32) { u32(UInt32(bitPattern: value)) }
    public mutating func i64(_ value: Int64) { u64(UInt64(bitPattern: value)) }
    public mutating func bool(_ value: Bool) { u8(value ? 1 : 0) }

    public mutating func f64(_ value: Double, _ what: String) throws {
        guard value.isFinite else { throw LinkError.invalidValue("non-finite number in \(what)") }
        u64(value.bitPattern)
    }

    public mutating func f32(_ value: Float, _ what: String) throws {
        guard value.isFinite else { throw LinkError.invalidValue("non-finite number in \(what)") }
        u32(value.bitPattern)
    }

    public mutating func string(_ value: String, maxBytes: Int, _ what: String) throws {
        let utf8 = value.utf8
        guard utf8.count <= maxBytes else { throw LinkError.limitExceeded("\(what) is \(utf8.count) bytes, limit \(maxBytes)") }
        u16(UInt16(utf8.count))
        bytes.append(contentsOf: utf8)
    }

    public mutating func blob(_ value: Data, maxBytes: Int, _ what: String) throws {
        guard value.count <= maxBytes else { throw LinkError.limitExceeded("\(what) is \(value.count) bytes, limit \(maxBytes)") }
        u32(UInt32(value.count))
        bytes.append(contentsOf: value)
    }

    public mutating func raw(_ value: Data) { bytes.append(contentsOf: value) }
    public mutating func bytes32(_ value: LinkBytes32) { raw(value.data) }

    /// Writes a count (`u16`) after checking it against `max`.
    public mutating func count(_ n: Int, max: Int, _ what: String) throws {
        guard n <= max else { throw LinkError.limitExceeded("\(what) count \(n), limit \(max)") }
        u16(UInt16(n))
    }

    public mutating func enumeration<E: RawRepresentable>(_ value: E) where E.RawValue == UInt8 { u8(value.rawValue) }

    public mutating func point(_ value: LinkPoint, _ what: String) throws {
        guard value.isValid else { throw LinkError.invalidValue("\(what) out of range") }
        try f64(value.x, what); try f64(value.y, what)
    }

    public mutating func size(_ value: LinkSize, _ what: String) throws {
        guard value.isValid else { throw LinkError.invalidValue("\(what) out of range") }
        try f64(value.width, what); try f64(value.height, what)
    }

    public mutating func rect(_ value: LinkRect, _ what: String) throws {
        try point(value.origin, what); try size(value.size, what)
    }

    public mutating func scale(_ value: Double, _ what: String) throws {
        guard value > 0, value <= LinkLimits.maxScale else { throw LinkError.invalidValue("\(what) out of range") }
        try f64(value, what)
    }

    public mutating func pixelDimension(_ value: UInt32, _ what: String) throws {
        guard value >= 1, value <= LinkLimits.maxPixelDimension else { throw LinkError.invalidValue("\(what) out of range") }
        u32(value)
    }
}
