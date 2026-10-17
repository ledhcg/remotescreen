import Darwin
import Foundation

/// Recognises Tailscale addresses and names.
public enum TailscaleNetwork {
    /// The MagicDNS suffix of a tailnet.
    static let magicDNSSuffix = ".ts.net"

    /// Whether reaching `host` goes through Tailscale: an address Tailscale assigns (100.64.0.0/10, fd7a:115c:a1e0::/48) or a
    /// MagicDNS name (`mac.tailnet-name.ts.net`). Short MagicDNS names without the suffix cannot be told apart from LAN names.
    public static func isTailscaleHost(_ host: String) -> Bool {
        let trimmed = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        if trimmed.hasSuffix(magicDNSSuffix) || trimmed.hasSuffix(magicDNSSuffix + ".") { return true }
        return isTailscaleAddress(trimmed)
    }

    /// Whether `text` is a numeric address in a range Tailscale assigns.
    public static func isTailscaleAddress(_ text: String) -> Bool {
        var v4 = in_addr()
        if inet_pton(AF_INET, text, &v4) == 1 {
            let value = UInt32(bigEndian: v4.s_addr)
            return value & 0xFFC0_0000 == 0x6440_0000 // 100.64.0.0/10
        }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, text, &v6) == 1 {
            let bytes = withUnsafeBytes(of: v6) { Array($0.prefix(6)) }
            return bytes == [0xFD, 0x7A, 0x11, 0x5C, 0xA1, 0xE0] // fd7a:115c:a1e0::/48
        }
        return false
    }

    /// This device's Tailscale address among `interfaces` (name, numeric address) pairs: an address in a Tailscale range on a
    /// tunnel (`utun`) interface. IPv4 is preferred.
    public static func deviceAddress(in interfaces: [(name: String, address: String)]) -> String? {
        let tunnel = interfaces.filter { $0.name.hasPrefix("utun") && isTailscaleAddress($0.address) }
        return (tunnel.first { !$0.address.contains(":") } ?? tunnel.first)?.address
    }

    /// The (name, numeric address) pairs of the interfaces that are up and running, loopback excluded.
    public static func runningInterfaceAddresses() -> [(name: String, address: String)] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var result: [(name: String, address: String)] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard let address = entry.ifa_addr else { continue }
            let family = Int32(address.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { continue }
            let flags = Int32(entry.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0
            else { continue }
            let text = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            // A scoped IPv6 address ends with "%interface".
            result.append((String(cString: entry.ifa_name), String(text.split(separator: "%").first ?? "")))
        }
        return result
    }
}
