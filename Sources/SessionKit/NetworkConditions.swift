import ConnectionKit
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
