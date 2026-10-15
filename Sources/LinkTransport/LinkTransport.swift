import LinkProtocol

/// Screon link transport (QUIC/TLS, identities, pairing). See docs/app-mode-implementation-plan.md M2.
public enum LinkTransportInfo {
    public static let alpn = "screon-link/1"
    public static let bonjourServiceType = "_screon-link._udp"
}
