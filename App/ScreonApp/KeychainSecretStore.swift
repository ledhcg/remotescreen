import ConnectionKit
import Foundation
import Security

struct KeychainError: Error, LocalizedError {
    let status: OSStatus

    var errorDescription: String? {
        "Keychain: " + ((SecCopyErrorMessageString(status, nil) as String?) ?? String(localized: "error \(status)"))
    }
}

/// Passwords in the device Keychain, one item per connection, keyed by `id`.
///
/// `WhenUnlockedThisDeviceOnly`: readable only while the device is unlocked, and never backed up or synced to other devices.
struct KeychainSecretStore: SecretStore {
    let service: String

    init(service: String = "com.ledinhcuong.screon.connection") {
        self.service = service
    }

    private func query(_ id: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
        ]
    }

    func password(for id: UUID) throws -> String? {
        var request = query(id)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw KeychainError(status: status) }
        return String(data: data, encoding: .utf8)
    }

    func setPassword(_ password: String, for id: UUID) throws {
        let data = Data(password.utf8)
        let status = SecItemUpdate(query(id) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        switch status {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var add = query(id)
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let added = SecItemAdd(add as CFDictionary, nil)
            guard added == errSecSuccess else { throw KeychainError(status: added) }
        default:
            throw KeychainError(status: status)
        }
    }

    func removePassword(for id: UUID) throws {
        let status = SecItemDelete(query(id) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }
}
