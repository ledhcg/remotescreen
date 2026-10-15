import Foundation

/// Số hiệu encoding của một hình chữ nhật trong `FramebufferUpdate` (số nguyên có dấu 32-bit).
/// Giá trị âm là pseudo-encoding: không mang pixel mà mang thông tin khác (con trỏ, kích thước...).
///
/// Dùng struct thay cho enum để giữ nguyên giá trị lạ mà server Apple có thể gửi.
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
