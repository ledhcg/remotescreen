import Foundation

/// Encoding number of a rectangle in `FramebufferUpdate` (32-bit signed integer).
/// Negative values are pseudo-encodings: they carry no pixels but other information (cursor, size, ...).
///
/// Uses a struct instead of an enum to preserve unknown values that Apple's server may send.
public struct RFBEncoding: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: Int32

    public init(rawValue: Int32) {
        self.rawValue = rawValue
    }

    public static let raw = RFBEncoding(rawValue: 0)
    public static let copyRect = RFBEncoding(rawValue: 1)
    public static let rre = RFBEncoding(rawValue: 2)
    public static let hextile = RFBEncoding(rawValue: 5)
    public static let zlib = RFBEncoding(rawValue: 6)
    public static let tight = RFBEncoding(rawValue: 7)
    public static let zrle = RFBEncoding(rawValue: 16)

    // Pseudo-encoding
    public static let desktopSize = RFBEncoding(rawValue: -223)
    public static let lastRect = RFBEncoding(rawValue: -224)
    public static let cursor = RFBEncoding(rawValue: -239)
    public static let extendedDesktopSize = RFBEncoding(rawValue: -308)

    public var description: String {
        switch self {
        case .raw: "Raw"
        case .copyRect: "CopyRect"
        case .rre: "RRE"
        case .hextile: "Hextile"
        case .zlib: "Zlib"
        case .tight: "Tight"
        case .zrle: "ZRLE"
        case .desktopSize: "DesktopSize"
        case .lastRect: "LastRect"
        case .cursor: "Cursor"
        case .extendedDesktopSize: "ExtendedDesktopSize"
        default: "encoding(\(rawValue))"
        }
    }
}
