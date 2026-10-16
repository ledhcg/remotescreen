import Darwin
import Foundation

/// What the device's network looks like right now, as far as reaching a Mac is concerned. Built by the app from
/// `NWPathMonitor` and the device's interface addresses; pure data so every decision below can be tested.
public struct NetworkSnapshot: Equatable, Sendable {
    /// The physical link carrying traffic. A VPN tunnel (Tailscale) is not a link: it rides on one of these.
    public enum Link: String, Equatable, Sendable {
        case wifi, cellular, wired, other, none
    }

    public var isOnline: Bool
    public var link: Link
    /// This device's own Tailscale address (100.64.0.0/10 or fd7a:115c:a1e0::/48 on a tunnel interface), when Tailscale is
    /// connected on this device.
    public var tailscaleAddress: String?

    public init(isOnline: Bool, link: Link, tailscaleAddress: String? = nil) {
        self.isOnline = isOnline
        self.link = link
        self.tailscaleAddress = tailscaleAddress
    }

    public var usesTailscale: Bool { tailscaleAddress != nil }

    public static let offline = NetworkSnapshot(isOnline: false, link: .none)
}

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

/// Checks made before connecting, so the user gets a clear reason at once instead of a timeout.
public enum NetworkPrecheck {
    public enum Problem: Equatable, Sendable {
        /// The device has no network at all.
        case offline
        /// The address is a Tailscale one but Tailscale is not connected on this device.
        case tailscaleNotConnected(host: String)
        /// The address is a Tailscale one but the user turned Tailscale off in Screon.
        case tailscaleTurnedOff(host: String)
    }

    public static func problem(host: String, network: NetworkSnapshot, useTailscale: Bool) -> Problem? {
        guard network.isOnline else { return .offline }
        guard TailscaleNetwork.isTailscaleHost(host) else { return nil }
        if !useTailscale { return .tailscaleTurnedOff(host: host) }
        if !network.usesTailscale { return .tailscaleNotConnected(host: host) }
        return nil
    }

    public static func message(for problem: Problem) -> String {
        switch problem {
        case .offline:
            return tr("This device is offline. Turn on Wi-Fi or mobile data, then try again.")
        case .tailscaleNotConnected(let host):
            return tr("%@ is a Tailscale address, but Tailscale is not connected on this device. Open the Tailscale app, connect, then try again.", host)
        case .tailscaleTurnedOff(let host):
            return tr("%@ is a Tailscale address, and Use Tailscale is turned off in Screon's network settings.", host)
        }
    }
}

/// Orders the addresses of a paired Mac helper for the network the device is on.
public enum HostOrdering {
    /// - Tailscale addresses are dropped when the user turned Tailscale off or it is not connected here: they cannot answer,
    ///   and each one would cost a connection timeout.
    /// - On mobile data the Mac's LAN addresses cannot answer either, so Tailscale addresses go first.
    /// - Otherwise the order is kept: the address that worked last comes first.
    public static func order(_ hosts: [String], network: NetworkSnapshot, useTailscale: Bool) -> [String] {
        let tailscaleUsable = useTailscale && network.usesTailscale
        let usable = hosts.filter { tailscaleUsable || !TailscaleNetwork.isTailscaleHost($0) }
        guard tailscaleUsable, network.link == .cellular else { return usable }
        return usable.filter(TailscaleNetwork.isTailscaleHost) + usable.filter { !TailscaleNetwork.isTailscaleHost($0) }
    }
}

/// What to do with a connection when the network changes under it.
///
/// A TCP or QUIC connection survives a short drop on the same network (the addresses do not change), so reconnecting then would
/// only cost a sign-in; but it cannot survive a change of link (Wi-Fi to mobile data) or a long outage, where waiting for the
/// transport to notice would leave the screen frozen for half a minute or more. Through Tailscale the tunnel hides link changes
/// from the connection, so only the tunnel itself coming back matters.
public enum NetworkRecovery {
    public enum Session: Equatable, Sendable {
        /// Connected and working, as far as the app knows.
        case live
        /// Lost; waiting before the next reconnect attempt.
        case waitingToRetry
        /// Nothing to do: not connected, or connecting.
        case inactive
    }

    public enum Action: Equatable, Sendable {
        case none
        /// Make the next reconnect attempt now instead of waiting out the backoff.
        case retryNow
        /// Close the connection and reconnect: it is dead or soon will be.
        case reconnect
    }

    /// Outages at least this long end a live connection; shorter ones are left to the transport.
    public static let longOutage: Duration = .seconds(3)

    /// - Parameters:
    ///   - before: the last snapshot while the device was online (before an outage, or simply the previous one).
    ///   - after: the snapshot now.
    ///   - outage: how long the device was offline, when this change ends an outage.
    ///   - viaTailscale: the connection goes to a Tailscale address.
    public static func action(
        before: NetworkSnapshot, after: NetworkSnapshot, outage: Duration?, session: Session, viaTailscale: Bool
    ) -> Action {
        guard after.isOnline, before != after || outage != nil else { return .none }
        switch session {
        case .inactive:
            return .none
        case .waitingToRetry:
            return .retryNow
        case .live:
            if viaTailscale {
                if !before.usesTailscale && after.usesTailscale { return .reconnect }
                if let outage, outage >= longOutage { return .reconnect }
                return .none
            }
            if before.link != after.link { return .reconnect }
            if let outage, outage >= longOutage { return .reconnect }
            return .none
        }
    }
}
