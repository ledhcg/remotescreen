import Foundation
import Network

/// Bonjour advertisement and discovery of helpers (`_screon-link._udp`).
///
/// The TXT record is **untrusted and informational only**: `v=1` and `fp=` the first 8 hex digits of the helper's SPKI hash.
/// Trust comes only from the pinned SPKI hash checked in the TLS handshake; the fingerprint merely lets the UI show which
/// saved computer a service probably is.
public enum LinkBonjour {
    public static let version = "1"
    public static let fingerprintLength = 8
    public static let maxTXTValueBytes = 64

    public static func fingerprint(spkiHash: Data) -> String {
        spkiHash.prefix(fingerprintLength / 2).map { String(format: "%02x", $0) }.joined()
    }

    public static func txtRecord(spkiHash: Data) -> NWTXTRecord {
        var txt = NWTXTRecord()
        txt["v"] = version
        txt["fp"] = fingerprint(spkiHash: spkiHash)
        return txt
    }

    public struct Advertisement: Sendable, Equatable {
        public var version: String
        /// 8 lowercase hex digits, or `nil` when absent or malformed.
        public var fingerprint: String?
    }

    /// Parses a TXT record from the network. Anything unexpected is ignored; nothing here is trusted.
    public static func parse(_ txt: NWTXTRecord) -> Advertisement? {
        guard let v = txt["v"], v.utf8.count <= maxTXTValueBytes, v == version else { return nil }
        var fp: String?
        if let raw = txt["fp"], raw.utf8.count == fingerprintLength,
           raw.utf8.allSatisfy({ ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) }) {
            fp = raw
        }
        return Advertisement(version: v, fingerprint: fp)
    }

    /// A helper found on the network.
    public struct Discovered: Sendable, Equatable {
        public var name: String
        public var endpoint: NWEndpoint
        public var advertisement: Advertisement
    }

    /// Browses for helpers. The stream yields the full current list on every change; it ends when the consumer stops.
    public static func browse(queue: DispatchQueue = DispatchQueue(label: "screon.link.browse")) -> AsyncStream<[Discovered]> {
        AsyncStream { continuation in
            let browser = NWBrowser(for: .bonjourWithTXTRecord(type: LinkTransportInfo.bonjourServiceType, domain: nil), using: .init())
            browser.browseResultsChangedHandler = { results, _ in
                let found: [Discovered] = results.prefix(64).compactMap { result in
                    guard case .service(let name, _, _, _) = result.endpoint,
                          case .bonjour(let txt) = result.metadata, let ad = parse(txt)
                    else { return nil }
                    return Discovered(name: String(name.prefix(100)), endpoint: result.endpoint, advertisement: ad)
                }
                continuation.yield(found)
            }
            continuation.onTermination = { _ in browser.cancel() }
            browser.start(queue: queue)
        }
    }
}
