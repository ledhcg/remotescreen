import Foundation

/// Loại bảo mật mà server cho phép chọn trong handshake.
///
/// Dùng struct thay cho enum để **giữ nguyên** giá trị lạ. Một số server (Apple) cung
/// cấp type không có trong đặc tả, và ta cần nhìn thấy chúng khi khám phá giao thức.
public struct RFBSecurityType: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let invalid = RFBSecurityType(rawValue: 0)
    /// Không xác thực. Tên cố ý KHÔNG là `none`: với giá trị `Optional<RFBSecurityType>`, `== .noAuthentication` sẽ bị hiểu là `nil`.
    public static let noAuthentication = RFBSecurityType(rawValue: 1)
    public static let vncAuthentication = RFBSecurityType(rawValue: 2)
    public static let tight = RFBSecurityType(rawValue: 16)
    public static let vencrypt = RFBSecurityType(rawValue: 19)
    /// Apple Remote Desktop (Diffie-Hellman + AES). Số hiệu này theo mô tả cộng đồng,
    /// và `rfbprobe` sẽ xác nhận nó có thực sự xuất hiện trên server của Apple hay không.
    public static let appleRemoteDesktop = RFBSecurityType(rawValue: 30)

    /// Tên đã biết, hoặc `nil` nếu là giá trị lạ.
    public var knownName: String? {
        switch self {
        case .invalid: "Invalid"
        case .noAuthentication: "None"
        case .vncAuthentication: "VNC Authentication"
        case .tight: "Tight"
        case .vencrypt: "VeNCrypt"
        case .appleRemoteDesktop: "Apple Remote Desktop"
        default: nil
        }
    }

    public var description: String {
        if let knownName { return "\(rawValue) (\(knownName))" }
        return "\(rawValue) (chưa biết)"
    }
}
