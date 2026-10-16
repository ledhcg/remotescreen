import Foundation
import Network

/// A stable, bounded key for "the same remote host", used only to rate limit pairing.
enum LinkRemoteAddress {
    static let unknown = "unknown"

    /// IPv4 addresses are used as they are; IPv6 addresses are reduced to their /64 prefix (a host can pick any address in
    /// its prefix, so the full address would let it dodge a per-address limit). The port and any interface scope are dropped.
    static func key(for endpoint: NWEndpoint?) -> String {
        guard case .hostPort(let host, _)? = endpoint else { return unknown }
        switch host {
        case .ipv4(let a):
            return "v4:" + a.rawValue.map(String.init).joined(separator: ".")
        case .ipv6(let a):
            if let v4 = a.asIPv4 { return "v4:" + v4.rawValue.map(String.init).joined(separator: ".") }
            return "v6:" + a.rawValue.prefix(8).map { String(format: "%02x", $0) }.joined()
        case .name(let name, _):
            return "name:" + name.lowercased()
        @unknown default:
            return unknown
        }
    }
}
