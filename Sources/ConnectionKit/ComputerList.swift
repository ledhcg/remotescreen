import Foundation

/// A row on the computer picker screen: a saved computer, or one newly found on the network.
public struct ComputerRow: Identifiable, Equatable, Sendable {
    public enum Source: Equatable, Sendable {
        case saved(SavedConnection)
        case discovered(DiscoveredHost)
    }

    public var source: Source
    /// `true` while Bonjour sees this computer. Not seeing it does **not** mean it is off: for a computer saved by address we cannot tell.
    public var isOnline: Bool

    public var id: String {
        switch source {
        case .saved(let connection): "saved-\(connection.id.uuidString)"
        case .discovered(let host): "found-\(host.id)"
        }
    }

    public var name: String {
        switch source {
        case .saved(let connection): connection.name
        case .discovered(let host): host.name
        }
    }

    /// Secondary line: `account@host` for a saved computer, "Screen Sharing" for a newly discovered one.
    public var subtitle: String {
        switch source {
        case .saved(let connection): connection.username.isEmpty ? connection.detail : "\(connection.username)@\(connection.detail)"
        case .discovered: tr("Screen Sharing")
        }
    }

    public var target: SavedConnection.Target {
        switch source {
        case .saved(let connection): connection.target
        case .discovered(let host): host.target
        }
    }
}

/// Merges the saved computers with those Bonjour can see into two display groups.
public enum ComputerList {
    public struct Sections: Equatable, Sendable {
        public var saved: [ComputerRow]
        public var nearby: [ComputerRow]
        public var isEmpty: Bool { saved.isEmpty && nearby.isEmpty }
    }

    /// - `saved`: keeps the given order (usually most recently used first).
    /// - `nearby`: only computers **not** already in the saved list, so a computer does not appear twice.
    public static func sections(saved: [SavedConnection], discovered: [DiscoveredHost]) -> Sections {
        let discoveredKeys = Set(discovered.compactMap(\.target.bonjourKey))
        let savedKeys = Set(saved.compactMap(\.target.bonjourKey))
        return Sections(
            saved: saved.map { row in
                ComputerRow(source: .saved(row), isOnline: row.target.bonjourKey.map(discoveredKeys.contains) ?? false)
            },
            nearby: discovered
                .filter { !savedKeys.contains($0.target.bonjourKey ?? "") }
                .map { ComputerRow(source: .discovered($0), isOnline: true) }
        )
    }
}

private extension SavedConnection.Target {
    /// Comparison key for a Bonjour service; `nil` for a computer saved by address (it cannot be compared with a service).
    var bonjourKey: String? {
        if case .bonjour(let name, let type, let domain) = self { return "\(name).\(type)\(domain)" }
        return nil
    }
}
