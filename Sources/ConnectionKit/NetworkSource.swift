import Foundation

/// Which network a computer was found on and is reached through. It decides how the computer is drawn in the list (Tailscale
/// computers get a black tile instead of the blue one) and is saved with the computer, so an offline Tailscale computer still looks like one.
public enum NetworkSource: String, Codable, Sendable, CaseIterable {
    /// The local network: found by Bonjour, or reached by a LAN address or a `.local` name.
    case lan
    /// A Tailscale tailnet: a 100.64.0.0/10 or fd7a:115c:a1e0::/48 address, a `.ts.net` name, or a device of the user's tailnet.
    case tailscale

    public init(host: String) {
        self = TailscaleNetwork.isTailscaleHost(host) ? .tailscale : .lan
    }

    public init(target: SavedConnection.Target) {
        switch target {
        case .host(let host, _): self.init(host: host)
        case .bonjour: self = .lan
        }
    }

    /// Short name for the secondary line of a row and for accessibility.
    public var title: String {
        switch self {
        case .lan: tr("Local network")
        case .tailscale: tr("Tailscale")
        }
    }
}
