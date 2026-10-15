import Foundation

/// Nơi giữ mật khẩu, khóa theo `id` của kết nối. Bản thật dùng Keychain (trong app); bản này để test và xem trước.
public protocol SecretStore: Sendable {
    func password(for id: UUID) throws -> String?
    func setPassword(_ password: String, for id: UUID) throws
    func removePassword(for id: UUID) throws
}

/// Kho mật khẩu trong bộ nhớ, dùng cho test.
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
