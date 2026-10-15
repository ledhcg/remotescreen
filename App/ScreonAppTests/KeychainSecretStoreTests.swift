import ConnectionKit
import Foundation
import Testing
@testable import ScreonApp

/// Runs in the simulator (real Keychain). Each test uses its own `service` and cleans up afterwards.
@Suite("KeychainSecretStore (real Keychain)")
struct KeychainSecretStoreTests {
    private func makeStore() -> KeychainSecretStore {
        KeychainSecretStore(service: "com.ledinhcuong.screon.tests.\(UUID().uuidString)")
    }

    @Test func missingPasswordIsNilNotAnError() throws {
        #expect(try makeStore().password(for: UUID()) == nil)
    }

    @Test func setReadReplaceRemove() throws {
        let store = makeStore()
        let id = UUID()
        defer { try? store.removePassword(for: id) }

        try store.setPassword("một", for: id)
        #expect(try store.password(for: id) == "một")
        try store.setPassword("hai", for: id) // replaces, no duplicate error
        #expect(try store.password(for: id) == "hai")
        try store.removePassword(for: id)
        #expect(try store.password(for: id) == nil)
    }

    @Test func removingAMissingPasswordIsNotAnError() throws {
        try makeStore().removePassword(for: UUID())
    }

    @Test func unicodeAndLongPasswordsRoundTrip() throws {
        let store = makeStore()
        let id = UUID()
        defer { try? store.removePassword(for: id) }
        let password = "Mật khẩu đặc biệt 🔐 " + String(repeating: "ệ", count: 200)
        try store.setPassword(password, for: id)
        #expect(try store.password(for: id) == password)
    }

    @Test func passwordsAreIsolatedByServiceAndByID() throws {
        let a = makeStore(), b = makeStore()
        let id = UUID(), other = UUID()
        defer { try? a.removePassword(for: id); try? a.removePassword(for: other) }
        try a.setPassword("của a", for: id)
        #expect(try b.password(for: id) == nil, "a different service cannot see it")
        #expect(try a.password(for: other) == nil, "a different id cannot see it")
    }
}
