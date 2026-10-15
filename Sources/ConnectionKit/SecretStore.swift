import Foundation

/// Where passwords are kept, keyed by the connection `id`. The real implementation uses the Keychain (in the app); this protocol also serves tests and previews.
public protocol SecretStore: Sendable {
    func password(for id: UUID) throws -> String?
    func setPassword(_ password: String, for id: UUID) throws
    func removePassword(for id: UUID) throws
}

/// In-memory password store, used for tests.
public final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var passwords: [UUID: String] = [:]

    public init() {}

    public func password(for id: UUID) throws -> String? {
        lock.withLock { passwords[id] }
    }

    public func setPassword(_ password: String, for id: UUID) throws {
        lock.withLock { passwords[id] = password }
    }

    public func removePassword(for id: UUID) throws {
        lock.withLock { _ = passwords.removeValue(forKey: id) }
    }
}
