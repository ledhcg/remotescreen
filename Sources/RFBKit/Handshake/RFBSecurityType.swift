import Foundation

/// Security type that the server offers for selection during the handshake.
///
/// Uses a struct instead of an enum to **preserve** unknown values. Some servers (Apple) offer
/// types that are not in the spec, and we need to see them during protocol discovery.
public struct RFBSecurityType: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let invalid = RFBSecurityType(rawValue: 0)
    /// No authentication. The name is deliberately NOT `none`: with an `Optional<RFBSecurityType>` value, `== .noAuthentication` would be read as `nil`.
    public static let noAuthentication = RFBSecurityType(rawValue: 1)
    public static let vncAuthentication = RFBSecurityType(rawValue: 2)
    public static let tight = RFBSecurityType(rawValue: 16)
    public static let vencrypt = RFBSecurityType(rawValue: 19)
    /// Apple Remote Desktop (Diffie-Hellman + AES). This number follows community descriptions,
    /// and `rfbprobe` will confirm whether it actually appears on Apple's server.
    public static let appleRemoteDesktop = RFBSecurityType(rawValue: 30)

    /// The known name, or `nil` for an unknown value.
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
        return "\(rawValue) (unknown)"
    }
}
