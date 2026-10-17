import Foundation
import Observation

/// The saved computers together with their passwords. The list lives in a JSON file, passwords in `SecretStore` (Keychain).
@MainActor
@Observable
public final class ConnectionsModel {
    public private(set) var list: ConnectionList
    /// The most recent save error, for the UI to report (saving happens after connecting, so there is nowhere to throw the error to).
    public var lastError: String?

    @ObservationIgnored private let store: ConnectionStore
    @ObservationIgnored private let secrets: SecretStore

    public init(store: ConnectionStore, secrets: SecretStore) {
        self.store = store
        self.secrets = secrets
        list = store.load()
    }

    /// In display order: most recently used first.
    public var saved: [SavedConnection] { list.sorted }

    /// Saves or updates a computer.
    ///
    /// - Parameter password: `nil` keeps the existing password; an empty string deletes it; any other string replaces it.
    /// - Throws: if writing the file fails, the in-memory state is **unchanged** (so we never show a computer that would vanish on next launch).
    public func save(_ connection: SavedConnection, password: String?) throws {
        var updated = list
        updated.upsert(connection)
        try store.save(updated)
        list = updated
        guard let password else { return }
        if password.isEmpty {
            try secrets.removePassword(for: connection.id)
        } else {
            try secrets.setPassword(password, for: connection.id)
        }
    }

    /// The saved computer with the same target and username, so reconnecting does not create a duplicate.
    public func matching(target: SavedConnection.Target, username: String) -> SavedConnection? {
        list.items.first { $0.target == target && $0.username == username }
    }

    /// The saved computer for a target, regardless of username. If there are several accounts, takes the most recently used. Used to prefill
    /// the username when the user taps a computer in the Bonjour list that they have signed in to before.
    public func connection(for target: SavedConnection.Target) -> SavedConnection? {
        saved.first { $0.target == target }
    }

    /// Remembers a computer that just connected successfully: updates it if one with the same target and username exists (no duplicate), then moves it
    /// to the top of the list. A save error is not thrown but stored in `lastError`, because this happens after connecting and nothing is left to receive it.
    public func remember(
        target: SavedConnection.Target, username: String, password: String, name: String, network: NetworkSource? = nil
    ) {
        var connection = matching(target: target, username: username)
            ?? SavedConnection(name: name, target: target, username: username)
        // The network it was found on wins (a Tailscale device picked from the list); else keep what is saved; else read it off the address.
        connection.networkSource = network ?? connection.networkSource ?? NetworkSource(target: target)
        do {
            try save(connection, password: password)
            markUsed(connection)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Deletes the computer and its password, so the Keychain keeps no leftovers.
    public func delete(_ connection: SavedConnection) throws {
        var updated = list
        updated.remove(id: connection.id)
        try store.save(updated)
        list = updated
        try secrets.removePassword(for: connection.id)
    }

    public func password(for connection: SavedConnection) -> String? {
        (try? secrets.password(for: connection.id)) ?? nil
    }

    /// Records that it just connected, so this computer moves to the top of the list. A file write error is ignored: this is only display order.
    public func markUsed(_ connection: SavedConnection, at date: Date = Date()) {
        var updated = list
        updated.markUsed(id: connection.id, at: date)
        guard (try? store.save(updated)) != nil else { return }
        list = updated
    }
}
