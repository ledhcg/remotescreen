import Foundation
import Testing
@testable import ConnectionKit

/// Kho mật khẩu ghi lại mọi lời gọi, và có thể bị ép lỗi.
private final class SpySecrets: SecretStore, @unchecked Sendable {
    let inner = InMemorySecretStore()
    private let lock = NSLock()
    private(set) var removed: [UUID] = []
    var failOnSet = false

    struct Failure: Error {}

    func password(for id: UUID) throws -> String? { try inner.password(for: id) }
    func setPassword(_ password: String, for id: UUID) throws {
        if failOnSet { throw Failure() }
        try inner.setPassword(password, for: id)
    }
    func removePassword(for id: UUID) throws {
        lock.withLock { removed.append(id) }
        try inner.removePassword(for: id)
    }
}

@MainActor
@Suite("ConnectionsModel")
struct ConnectionsModelTests {
    private func makeModel(secrets: SecretStore = InMemorySecretStore()) -> (ConnectionsModel, ConnectionStore, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ConnectionsModelTests-\(UUID().uuidString)")
        let store = ConnectionStore(fileURL: directory.appendingPathComponent("connections.json"))
        return (ConnectionsModel(store: store, secrets: secrets), store, directory)
    }

    private func sample(_ name: String = "Mac mini") -> SavedConnection {
        SavedConnection(name: name, target: .host("mac.local", port: 5900), username: "alice")
    }

    @Test func savedConnectionsSurviveARestart() throws {
        let secrets = InMemorySecretStore()
        let (model, store, directory) = makeModel(secrets: secrets)
        defer { try? FileManager.default.removeItem(at: directory) }
        let connection = sample()
        try model.save(connection, password: "bí mật")

        let reopened = ConnectionsModel(store: store, secrets: secrets)
        #expect(reopened.saved == [connection])
        #expect(reopened.password(for: connection) == "bí mật")
    }

    @Test func nilKeepsPasswordEmptyRemovesItAndTextReplacesIt() throws {
        let (model, _, directory) = makeModel()
        defer { try? FileManager.default.removeItem(at: directory) }
        let connection = sample()
        try model.save(connection, password: "một")
        try model.save(connection, password: nil)
        #expect(model.password(for: connection) == "một", "nil giữ nguyên mật khẩu")
        try model.save(connection, password: "hai")
        #expect(model.password(for: connection) == "hai")
        try model.save(connection, password: "")
        #expect(model.password(for: connection) == nil, "chuỗi rỗng xóa mật khẩu")
    }

    @Test func deleteRemovesTheConnectionAndItsPassword() throws {
        let spy = SpySecrets()
        let (model, store, directory) = makeModel(secrets: spy)
        defer { try? FileManager.default.removeItem(at: directory) }
        let connection = sample()
        try model.save(connection, password: "x")
        try model.delete(connection)
        #expect(model.saved.isEmpty)
        #expect(spy.removed == [connection.id], "phải xóa mật khẩu khỏi Keychain, không để lại rác")
        #expect(store.load().items.isEmpty)
    }

    /// Ghi file lỗi thì bộ nhớ không được đổi: nếu không, danh sách hiện một máy mà lần mở sau sẽ mất.
    @Test func failedFileWriteLeavesMemoryUnchanged() throws {
        let (model, store, directory) = makeModel()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = sample("Một")
        try model.save(first, password: nil)

        // Biến đường dẫn file thành một thư mục thật để lần ghi kế tiếp chắc chắn lỗi.
        try FileManager.default.removeItem(at: store.fileURL)
        try FileManager.default.createDirectory(at: store.fileURL, withIntermediateDirectories: true)

        #expect(throws: (any Error).self) { try model.save(sample("Hai"), password: nil) }
        #expect(model.saved == [first])
        #expect(throws: (any Error).self) { try model.delete(first) }
        #expect(model.saved == [first])
    }

    @Test func passwordFailureStillKeepsTheSavedConnectionButReportsTheError() throws {
        let spy = SpySecrets()
        spy.failOnSet = true
        let (model, _, directory) = makeModel(secrets: spy)
        defer { try? FileManager.default.removeItem(at: directory) }
        let connection = sample()
        #expect(throws: SpySecrets.Failure.self) { try model.save(connection, password: "x") }
        #expect(model.saved == [connection], "máy vẫn được lưu để người dùng nhập lại mật khẩu sau")
        #expect(model.password(for: connection) == nil)
    }

    @Test func markUsedMovesTheConnectionToTheTop() throws {
        let (model, _, directory) = makeModel()
        defer { try? FileManager.default.removeItem(at: directory) }
        let a = sample("A"), b = sample("B")
        try model.save(a, password: nil)
        try model.save(b, password: nil)
        #expect(model.saved.map(\.name) == ["A", "B"])
        model.markUsed(b, at: Date(timeIntervalSince1970: 50))
        #expect(model.saved.map(\.name) == ["B", "A"])
    }

    @Test func unknownPasswordIsNilNotACrash() {
        let (model, _, directory) = makeModel()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(model.password(for: sample()) == nil)
    }
}

@MainActor
@Suite("ConnectionsModel: nhận diện trùng")
struct ConnectionsModelMatchingTests {
    @Test func matchesBySameTargetAndUsernameOnly() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Matching-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = ConnectionsModel(store: ConnectionStore(fileURL: directory.appendingPathComponent("c.json")), secrets: InMemorySecretStore())
        let mac = SavedConnection(name: "Mac", target: .host("mac.local", port: 5900), username: "a")
        try model.save(mac, password: nil)

        #expect(model.matching(target: .host("mac.local", port: 5900), username: "a") == mac)
        #expect(model.matching(target: .host("mac.local", port: 5900), username: "b") == nil, "tài khoản khác là máy khác")
        #expect(model.matching(target: .host("mac.local", port: 5901), username: "a") == nil, "cổng khác là máy khác")
        #expect(model.matching(target: .host("other.local", port: 5900), username: "a") == nil)
    }
}

@MainActor
@Suite("ConnectionsModel: ghi nhớ sau khi kết nối")
struct ConnectionsModelRememberTests {
    private func makeModel() -> (ConnectionsModel, InMemorySecretStore, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Remember-\(UUID().uuidString)")
        let secrets = InMemorySecretStore()
        let store = ConnectionStore(fileURL: directory.appendingPathComponent("c.json"))
        return (ConnectionsModel(store: store, secrets: secrets), secrets, directory)
    }

    private let target = SavedConnection.Target.host("mac.local", port: 5900)

    @Test func firstConnectionIsSavedWithItsPasswordAndMarkedUsed() throws {
        let (model, secrets, directory) = makeModel()
        defer { try? FileManager.default.removeItem(at: directory) }
        model.remember(target: target, username: "u", password: "p", name: "Mac")
        let saved = try #require(model.saved.first)
        #expect(saved.name == "Mac" && saved.username == "u")
        #expect(saved.lastUsed != nil)
        #expect(try secrets.password(for: saved.id) == "p")
        #expect(model.lastError == nil)
    }

    @Test func connectingAgainUpdatesInsteadOfDuplicating() throws {
        let (model, secrets, directory) = makeModel()
        defer { try? FileManager.default.removeItem(at: directory) }
        model.remember(target: target, username: "u", password: "cũ", name: "Mac")
        model.remember(target: target, username: "u", password: "mới", name: "Tên khác")
        #expect(model.saved.count == 1)
        let saved = try #require(model.saved.first)
        #expect(saved.name == "Mac", "giữ tên cũ, không đổi theo lần kết nối sau")
        #expect(try secrets.password(for: saved.id) == "mới")
    }

    @Test func differentUsernameIsAnotherEntry() {
        let (model, _, directory) = makeModel()
        defer { try? FileManager.default.removeItem(at: directory) }
        model.remember(target: target, username: "a", password: "1", name: "Mac")
        model.remember(target: target, username: "b", password: "2", name: "Mac")
        #expect(model.saved.count == 2)
    }

    @Test func failureGoesToLastErrorAndDoesNotThrow() throws {
        let (model, _, directory) = makeModel()
        defer { try? FileManager.default.removeItem(at: directory) }
        model.remember(target: target, username: "u", password: "p", name: "Mac")
        // Biến đường dẫn file thành thư mục để lần ghi kế tiếp lỗi.
        let file = directory.appendingPathComponent("c.json")
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)

        model.remember(target: .host("khac.local", port: 5900), username: "u", password: "p", name: "Khác")
        #expect(model.lastError != nil)
        #expect(model.saved.count == 1, "lần lưu lỗi không được đổi bộ nhớ")
    }
}
