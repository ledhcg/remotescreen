import Foundation

/// A saved computer. The password is **not** stored here but in `SecretStore` (Keychain), keyed by `id`.
public struct SavedConnection: Codable, Identifiable, Equatable, Sendable {
    /// How to find the computer: by address, or by Bonjour service (independent of an IP that changes with DHCP).
    public enum Target: Codable, Equatable, Sendable {
        case host(String, port: UInt16)
        case bonjour(name: String, type: String, domain: String)
    }

    public var id: UUID
    /// Display name in the list.
    public var name: String
    public var target: Target
    public var username: String
    public var lastUsed: Date?

    public init(id: UUID = UUID(), name: String, target: Target, username: String, lastUsed: Date? = nil) {
        self.id = id
        self.name = name
        self.target = target
        self.username = username
        self.lastUsed = lastUsed
    }

    /// Secondary line in the list: the address or the service name.
    public var detail: String {
        switch target {
        case .host(let host, let port): port == 5900 ? host : "\(host):\(port)"
        case .bonjour(let name, _, _): name
        }
    }
}

/// The list of saved computers. A pure value type, so every change can be tested without a disk.
public struct ConnectionList: Codable, Equatable, Sendable {
    public private(set) var items: [SavedConnection]

    public init(_ items: [SavedConnection] = []) {
        self.items = items
    }

    /// Adds a new entry, or replaces the one with the same `id`.
    public mutating func upsert(_ connection: SavedConnection) {
        if let index = items.firstIndex(where: { $0.id == connection.id }) {
            items[index] = connection
        } else {
            items.append(connection)
        }
    }

    public mutating func remove(id: UUID) {
        items.removeAll { $0.id == id }
    }

    public mutating func markUsed(id: UUID, at date: Date) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].lastUsed = date
    }

    /// Most recently used first; never-used computers come after, by name (case- and diacritic-insensitive).
    public var sorted: [SavedConnection] {
        items.sorted { a, b in
            switch (a.lastUsed, b.lastUsed) {
            case let (x?, y?) where x != y: return x > y
            case (.some, .none): return true
            case (.none, .some): return false
            default: return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
        }
    }
}
