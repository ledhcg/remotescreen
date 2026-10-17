import Foundation

/// A row on the computer picker screen: a saved computer, one newly found on the network, or a device of the user's tailnet.
public struct ComputerRow: Identifiable, Equatable, Sendable {
    public enum Source: Equatable, Sendable {
        case saved(SavedConnection)
        case discovered(DiscoveredHost)
        case tailnet(TailnetDevice)
    }

    public var source: Source
    /// `true` when the computer is available now: Bonjour sees it, or a probe of one of its addresses answered. `false` is "not seen": for a
    /// computer saved by address we cannot tell off from out of reach.
    public var isOnline: Bool

    public init(source: Source, isOnline: Bool) {
        self.source = source
        self.isOnline = isOnline
    }

    public var id: String {
        switch source {
        case .saved(let connection): "saved-\(connection.id.uuidString)"
        case .discovered(let host): "found-\(host.id)"
        case .tailnet(let device): "tailnet-\(device.id)"
        }
    }

    public var name: String {
        switch source {
        case .saved(let connection): connection.name
        case .discovered(let host): host.name
        case .tailnet(let device): device.hostname
        }
    }

    /// The network the row belongs to: it decides the colour of the tile.
    public var network: NetworkSource {
        switch source {
        case .saved(let connection): connection.network
        case .discovered: .lan
        case .tailnet: .tailscale
        }
    }

    /// Secondary line: `account@host` for a saved computer, "Screen Sharing" for a newly discovered one, the address of a tailnet device.
    public var subtitle: String {
        switch source {
        case .saved(let connection): connection.username.isEmpty ? connection.detail : "\(connection.username)@\(connection.detail)"
        case .discovered: tr("Screen Sharing")
        case .tailnet(let device): device.address ?? device.hostname
        }
    }

    /// `true` for a saved computer: only it has a password to enter again, a pairing to set up or a place in the list to delete.
    public var isSaved: Bool {
        if case .saved = source { return true }
        return false
    }

    public var target: SavedConnection.Target {
        switch source {
        case .saved(let connection): connection.target
        case .discovered(let host): host.target
        case .tailnet(let device): device.target ?? .host(device.hostname, port: TailnetDevice.screenSharingPort)
        }
    }
}

/// Merges the saved computers with those Bonjour can see and those of the tailnet into display groups.
public enum ComputerList {
    public struct Sections: Equatable, Sendable {
        public var saved: [ComputerRow]
        public var nearby: [ComputerRow]
        /// Devices of the user's tailnet that are Macs, not saved yet and answering on the Screen Sharing port.
        public var tailnet: [ComputerRow]
        public var isEmpty: Bool { saved.isEmpty && nearby.isEmpty && tailnet.isEmpty }

        public init(saved: [ComputerRow], nearby: [ComputerRow], tailnet: [ComputerRow] = []) {
            self.saved = saved
            self.nearby = nearby
            self.tailnet = tailnet
        }
    }

    /// - `saved`: keeps the given order (usually most recently used first). Online when Bonjour sees it or a probe of its addresses answered.
    /// - `nearby`: only computers **not** already in the saved list, so a computer does not appear twice.
    /// - `tailnet`: Macs of the tailnet not already saved; only those that answered a probe are listed (a Mac with Screen Sharing off
    ///   cannot be connected to, and the list would fill with machines that are of no use).
    /// - `reachable`: the probe targets that answered (see `ReachabilityMonitor`).
    public static func sections(
        saved: [SavedConnection], discovered: [DiscoveredHost], tailnet: [TailnetDevice] = [], reachable: Set<ProbeTarget> = []
    ) -> Sections {
        let discoveredKeys = Set(discovered.compactMap(\.target.bonjourKey))
        let savedKeys = Set(saved.compactMap(\.target.bonjourKey))
        return Sections(
            saved: saved.map { row in
                let seenByBonjour = row.target.bonjourKey.map(discoveredKeys.contains) ?? false
                let answered = row.probeTargets().contains(where: reachable.contains)
                return ComputerRow(source: .saved(row), isOnline: seenByBonjour || answered)
            },
            nearby: discovered
                .filter { !savedKeys.contains($0.target.bonjourKey ?? "") }
                .map { ComputerRow(source: .discovered($0), isOnline: true) },
            tailnet: tailnet
                .filter { device in device.canBeSharedScreen && !saved.contains(where: device.matches) }
                .filter { device in probeTarget(of: device).map(reachable.contains) ?? false }
                .map { ComputerRow(source: .tailnet($0), isOnline: true) }
        )
    }

    /// What to probe for a tailnet device: its Tailscale address on the Screen Sharing port.
    public static func probeTarget(of device: TailnetDevice) -> ProbeTarget? {
        device.address.map { ProbeTarget(host: $0, port: TailnetDevice.screenSharingPort) }
    }

    /// Everything the list needs probed: the saved computers' addresses and the tailnet Macs that are not saved.
    public static func probeTargets(saved: [SavedConnection], tailnet: [TailnetDevice]) -> Set<ProbeTarget> {
        var targets = Set(saved.flatMap { $0.probeTargets() })
        for device in tailnet where device.canBeSharedScreen && !saved.contains(where: device.matches) {
            if let target = probeTarget(of: device) { targets.insert(target) }
        }
        return targets
    }
}

private extension SavedConnection.Target {
    /// Comparison key for a Bonjour service; `nil` for a computer saved by address (it cannot be compared with a service).
    var bonjourKey: String? {
        if case .bonjour(let name, let type, let domain) = self { return "\(name).\(type)\(domain)" }
        return nil
    }
}
