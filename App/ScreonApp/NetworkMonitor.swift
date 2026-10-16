import Foundation
import Network
import Observation
import SessionKit

/// Network preferences of the whole app, kept in `UserDefaults` (the key is also used by `@AppStorage` in the settings sheet).
enum NetworkPreferences {
    static let useTailscaleKey = "network.useTailscale"

    /// Whether Screon may reach Macs through Tailscale. On by default: it is only used when Tailscale is connected on the device.
    static var useTailscale: Bool {
        UserDefaults.standard.object(forKey: useTailscaleKey) as? Bool ?? true
    }
}

/// Watches the device's network for the whole app: online or not, which link (Wi-Fi, mobile data, wired), and whether Tailscale
/// is connected on this device. Sessions register to hear about changes; the settings sheet shows the current state.
@MainActor
@Observable
final class NetworkMonitor {
    static let shared = NetworkMonitor()

    /// The newest snapshot. Optimistic (online) until the first path update, so a check made in the first instant after launch
    /// does not refuse to connect.
    private(set) var snapshot = NetworkSnapshot(isOnline: true, link: .other)

    @ObservationIgnored private var observers: [UUID: (NetworkSnapshot) -> Void] = [:]
    @ObservationIgnored private let monitor = NWPathMonitor()
    @ObservationIgnored private var started = false

    private init() {}

    func start() {
        guard !started else { return }
        started = true
        monitor.pathUpdateHandler = { path in
            // Tailscale is a VPN tunnel: its address appears on a `utun` interface, which a path update accompanies.
            let snapshot = NetworkSnapshot(
                isOnline: path.status == .satisfied,
                link: Self.link(of: path),
                tailscaleAddress: path.status == .satisfied
                    ? TailscaleNetwork.deviceAddress(in: TailscaleNetwork.runningInterfaceAddresses()) : nil
            )
            Task { @MainActor in NetworkMonitor.shared.update(snapshot) }
        }
        monitor.start(queue: DispatchQueue(label: "Screon.NetworkMonitor"))
    }

    /// Calls `handler` on every change, until the returned token is passed to `removeObserver`.
    func addObserver(_ handler: @escaping (NetworkSnapshot) -> Void) -> UUID {
        start()
        let id = UUID()
        observers[id] = handler
        return id
    }

    func removeObserver(_ id: UUID?) {
        guard let id else { return }
        observers[id] = nil
    }

    private func update(_ new: NetworkSnapshot) {
        guard new != snapshot else { return }
        snapshot = new
        for handler in observers.values { handler(new) }
    }

    /// The physical link under the path. With a VPN up the path's own interface is the tunnel (`.other`): look past it.
    nonisolated private static func link(of path: NWPath) -> NetworkSnapshot.Link {
        guard path.status == .satisfied else { return .none }
        for interface in path.availableInterfaces {
            switch interface.type {
            case .wifi: return .wifi
            case .cellular: return .cellular
            case .wiredEthernet: return .wired
            default: continue
            }
        }
        return .other
    }
}

/// Follows network changes for one connection: remembers the last snapshot while online and how long an outage lasted, and
/// turns each change into a `NetworkRecovery` decision.
@MainActor
final class NetworkWatch {
    private var token: UUID?
    private var lastOnline: NetworkSnapshot
    private var offlineSince: ContinuousClock.Instant?

    /// - Parameter onChange: the new snapshot and how long the device had been offline, when this change ends an outage.
    init(onChange: @escaping (_ before: NetworkSnapshot, _ after: NetworkSnapshot, _ outage: Duration?) -> Void) {
        let current = NetworkMonitor.shared.snapshot
        lastOnline = current
        offlineSince = current.isOnline ? nil : .now
        token = NetworkMonitor.shared.addObserver { [weak self] snapshot in
            guard let self else { return }
            if !snapshot.isOnline {
                if self.offlineSince == nil { self.offlineSince = .now }
                onChange(self.lastOnline, snapshot, nil)
                return
            }
            let outage = self.offlineSince.map { ContinuousClock.now - $0 }
            self.offlineSince = nil
            let before = self.lastOnline
            self.lastOnline = snapshot
            onChange(before, snapshot, outage)
        }
    }

    var isOnline: Bool { NetworkMonitor.shared.snapshot.isOnline }

    func stop() {
        NetworkMonitor.shared.removeObserver(token)
        token = nil
    }

    /// Waits until the device is online again, or the task is cancelled.
    func waitUntilOnline() async {
        while !Task.isCancelled, !NetworkMonitor.shared.snapshot.isOnline {
            try? await Task.sleep(for: .milliseconds(250))
        }
    }
}
