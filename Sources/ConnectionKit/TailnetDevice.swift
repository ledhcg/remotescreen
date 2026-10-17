import Foundation

/// A device of the user's tailnet, as the Tailscale API lists it.
public struct TailnetDevice: Identifiable, Equatable, Sendable {
    public var id: String
    /// Short host name (`mac-mini`).
    public var hostname: String
    /// MagicDNS name (`mac-mini.tailnet-name.ts.net`), when the tailnet has MagicDNS.
    public var dnsName: String?
    /// Tailscale addresses, IPv4 first.
    public var addresses: [String]
    /// Operating system as Tailscale reports it (`macOS`, `iOS`, `linux`, `windows`…).
    public var os: String

    public init(id: String, hostname: String, dnsName: String? = nil, addresses: [String], os: String) {
        self.id = id
        self.hostname = hostname
        self.dnsName = dnsName
        self.addresses = addresses
        self.os = os
    }

    /// The address to connect to: the IPv4 one (works without MagicDNS), else the first.
    public var address: String? {
        addresses.first { $0.contains(".") && TailscaleNetwork.isTailscaleAddress($0) }
            ?? addresses.first { TailscaleNetwork.isTailscaleAddress($0) }
    }

    /// Whether this device can be a screen sharing target. A phone or tablet of the tailnet cannot.
    public var canBeSharedScreen: Bool { os.lowercased() == "macos" }

    /// Target to save and connect to: the Tailscale address on the Screen Sharing port.
    public var target: SavedConnection.Target? {
        address.map { .host($0, port: TailnetDevice.screenSharingPort) }
    }

    public static let screenSharingPort: UInt16 = 5900

    /// Whether `connection` is this device (same Tailscale address, or the same MagicDNS name).
    public func matches(_ connection: SavedConnection) -> Bool {
        var hosts: [String] = []
        if case .host(let host, _) = connection.target { hosts.append(host) }
        hosts += connection.helper?.candidateHosts ?? []
        let known = Set(hosts.map { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[].")) })
        let mine = Set((addresses + [dnsName].compactMap { $0 }).map { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[].")) })
        return !known.isDisjoint(with: mine)
    }
}

/// Reads the device list of a tailnet from the Tailscale API.
///
/// iOS gives an app no access to the Tailscale app's own peer list, so the list comes from the API, with an API access token the
/// user creates in the Tailscale admin console. The token is sent only to `api.tailscale.com`, over HTTPS, in the
/// `Authorization` header: never in the URL, never logged.
public enum TailscaleAPI {
    public enum Failure: Error, Equatable, Sendable {
        /// The token is wrong, revoked or expired (HTTP 401 or 403).
        case unauthorized
        /// Tailscale answered something else than a device list.
        case unexpectedResponse
        /// The request did not complete: offline, timed out.
        case network
    }

    /// The most devices read from one answer; a hostile or broken answer cannot make the app hold an unbounded list.
    public static let maxDevices = 500

    static let devicesURL = URL(string: "https://api.tailscale.com/api/v2/tailnet/-/devices")!

    /// - Parameter session: tests pass one with a stub `URLProtocol`.
    public static func devices(token: String, session: URLSession = .shared) async throws -> [TailnetDevice] {
        var request = URLRequest(url: devicesURL, timeoutInterval: 15)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw Failure.network
        }
        guard let http = response as? HTTPURLResponse else { throw Failure.unexpectedResponse }
        switch http.statusCode {
        case 200: return try parse(data)
        case 401, 403: throw Failure.unauthorized
        default: throw Failure.unexpectedResponse
        }
    }

    /// `{"devices": [{"id", "hostname", "name", "addresses", "os"}]}`; a device without an id or without a Tailscale address is skipped.
    public static func parse(_ data: Data) throws -> [TailnetDevice] {
        struct Answer: Decodable {
            struct Device: Decodable {
                var id: String?
                var nodeId: String?
                var hostname: String?
                var name: String?
                var addresses: [String]?
                var os: String?
            }
            var devices: [Device]
        }
        guard data.count <= 8 << 20, let answer = try? JSONDecoder().decode(Answer.self, from: data) else { throw Failure.unexpectedResponse }
        var seen = Set<String>()
        var result: [TailnetDevice] = []
        for device in answer.devices.prefix(maxDevices) {
            let addresses = (device.addresses ?? []).filter { $0.utf8.count <= 64 && TailscaleNetwork.isTailscaleAddress($0) }
            guard let id = device.id ?? device.nodeId, !id.isEmpty, id.utf8.count <= 128, !addresses.isEmpty, seen.insert(id).inserted else { continue }
            let dns = device.name.map { $0.hasSuffix(".") ? String($0.dropLast()) : $0 }
            let hostname = (device.hostname?.isEmpty == false ? device.hostname : nil) ?? dns?.split(separator: ".").first.map(String.init) ?? id
            result.append(TailnetDevice(
                id: id, hostname: String(hostname.prefix(100)), dnsName: dns.map { String($0.prefix(253)) },
                addresses: addresses.sorted { !$0.contains(":") && $1.contains(":") }, os: String((device.os ?? "").prefix(32))))
        }
        return result.sorted { $0.hostname.localizedStandardCompare($1.hostname) == .orderedAscending }
    }
}
