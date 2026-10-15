import Foundation

/// A 32-bit identifier assigned by the helper and never reused within a session.
public protocol LinkIdentifier: RawRepresentable, Hashable, Sendable, Comparable, ExpressibleByIntegerLiteral where RawValue == UInt32 {
    init(rawValue: UInt32)
}

extension LinkIdentifier {
    public init(_ rawValue: UInt32) { self.init(rawValue: rawValue) }
    public init(integerLiteral value: UInt32) { self.init(rawValue: value) }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// A window on the Mac.
public struct WindowID: LinkIdentifier { public var rawValue: UInt32; public init(rawValue: UInt32) { self.rawValue = rawValue } }
/// A running or installed application (the helper's handle for it).
public struct AppRef: LinkIdentifier { public var rawValue: UInt32; public init(rawValue: UInt32) { self.rawValue = rawValue } }
/// A popup surface (menu, tooltip...) inside a window's stream.
public struct SurfaceID: LinkIdentifier { public var rawValue: UInt32; public init(rawValue: UInt32) { self.rawValue = rawValue } }
/// One file transfer.
public struct TransferID: LinkIdentifier { public var rawValue: UInt32; public init(rawValue: UInt32) { self.rawValue = rawValue } }
/// A cursor image the helper has sent (`cursor.shape`) and may refer to again (`cursor.ref`).
public struct CursorID: LinkIdentifier { public var rawValue: UInt32; public init(rawValue: UInt32) { self.rawValue = rawValue } }
/// Key of an application icon (`apps.icon`, `apps.iconData`).
public struct IconKey: LinkIdentifier { public var rawValue: UInt32; public init(rawValue: UInt32) { self.rawValue = rawValue } }

/// Exactly 32 bytes: SPKI hash, HMAC, challenge, resume token, X25519 key, SHA-256. Wrong sizes cannot be represented.
public struct LinkBytes32: Sendable, Hashable {
    public let data: Data

    public init(_ data: Data) throws {
        guard data.count == 32 else { throw LinkError.invalidValue("expected 32 bytes, got \(data.count)") }
        self.data = Data(data)
    }

    public init(_ bytes: [UInt8]) throws { try self.init(Data(bytes)) }
    /// All bytes equal to `byte`; convenient in tests.
    public init(repeating byte: UInt8) { data = Data(repeating: byte, count: 32) }
}

/// A point in Mac points. Finite and within `LinkLimits.maxCoordinate` when sent or accepted.
public struct LinkPoint: Sendable, Hashable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
    /// False for NaN, infinities and absurd magnitudes.
    public var isValid: Bool { abs(x) <= LinkLimits.maxCoordinate && abs(y) <= LinkLimits.maxCoordinate }
}

/// A size in Mac points. Non-negative, finite and bounded when sent or accepted.
public struct LinkSize: Sendable, Hashable {
    public var width: Double
    public var height: Double
    public init(width: Double, height: Double) { self.width = width; self.height = height }
    public var isValid: Bool {
        width >= 0 && width <= LinkLimits.maxCoordinate && height >= 0 && height <= LinkLimits.maxCoordinate
    }
}

/// A rectangle in Mac points.
public struct LinkRect: Sendable, Hashable {
    public var origin: LinkPoint
    public var size: LinkSize
    public init(origin: LinkPoint, size: LinkSize) { self.origin = origin; self.size = size }
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.init(origin: LinkPoint(x: x, y: y), size: LinkSize(width: width, height: height))
    }
    public var isValid: Bool { origin.isValid && size.isValid }
}
