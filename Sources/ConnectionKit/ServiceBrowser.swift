import Foundation
import Network
import Observation

/// A computer found via Bonjour (the `_rfb._tcp` service: macOS Screen Sharing and other VNC servers).
public struct DiscoveredHost: Identifiable, Hashable, Sendable {
    public var name: String
    public var type: String
    public var domain: String

    public init(name: String, type: String = ServiceBrowser.serviceType, domain: String = "local.") {
        self.name = name
        self.type = type
        self.domain = domain
    }

    public var id: String { "\(name).\(type)\(domain)" }

    /// Target to save and connect to: by service, independent of an IP that changes with DHCP.
    public var target: SavedConnection.Target { .bonjour(name: name, type: type, domain: domain) }
}

extension SavedConnection.Target {
    /// Endpoint for `NWConnection` to connect to. The system resolves a Bonjour service at connect time.
    public var endpoint: NWEndpoint {
        switch self {
        case .host(let host, let port):
            .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port) ?? .any)
        case .bonjour(let name, let type, let domain):
            .service(name: name, type: type, domain: domain, interface: nil)
        }
    }
}

/// Finds computers on the local network using Bonjour.
///
/// On first run, iOS asks for **Local Network** permission. If denied, `denied` becomes `true` and the list stays empty.
@MainActor
@Observable
public final class ServiceBrowser {
    public nonisolated static let serviceType = "_rfb._tcp"

    public private(set) var hosts: [DiscoveredHost] = []
    /// `true` when iOS blocks discovery because Local Network permission is missing.
    public private(set) var denied = false

    @ObservationIgnored private var browser: NWBrowser?
    /// The user is still on the computer picker: on failure, browse again instead of leaving the list frozen until they leave the screen.
    @ObservationIgnored private var wantsBrowsing = false
    static let restartDelay: Duration = .seconds(3)

    public init() {}

    /// Turns `NWBrowser` results into the display list: only Bonjour services, duplicates removed, sorted by name.
    nonisolated static func hosts(from endpoints: some Sequence<NWEndpoint>) -> [DiscoveredHost] {
        var seen = Set<DiscoveredHost>()
        for endpoint in endpoints {
            guard case let .service(name, type, domain, _) = endpoint else { continue }
            seen.insert(DiscoveredHost(name: name, type: type, domain: domain))
        }
        return seen.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public func start() {
        wantsBrowsing = true
        guard browser == nil else { return }
        let browser = NWBrowser(for: .bonjour(type: Self.serviceType, domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let found = Self.hosts(from: results.map(\.endpoint))
            Task { @MainActor in self?.hosts = found }
        }
        browser.stateUpdateHandler = { [weak self] state in
            let isDenied: Bool
            switch state {
            case .failed(let error), .waiting(let error):
                if case .dns(let code) = error, code == -65570 { isDenied = true } else { isDenied = false }
            default:
                isDenied = false
            }
            let failed: Bool
            if case .failed = state { failed = true } else { failed = false }
            Task { @MainActor in
                self?.denied = isDenied
                if failed { self?.restartAfterFailure() }
            }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    /// A failed `NWBrowser` does not restart itself, and `start()` also returns early because `browser` is still set. Clean it up and retry after a while.
    private func restartAfterFailure() {
        browser?.cancel()
        browser = nil
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.restartDelay)
            guard let self, self.wantsBrowsing, self.browser == nil else { return }
            self.start()
        }
    }

    public func stop() {
        wantsBrowsing = false
        browser?.cancel()
        browser = nil
        hosts = []
    }
}
