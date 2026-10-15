import Foundation
import Testing
@testable import ConnectionKit

private func connection(_ name: String, last: Double? = nil, id: UUID = UUID()) -> SavedConnection {
    SavedConnection(id: id, name: name, target: .host("\(name).local", port: 5900), username: "u",
                    lastUsed: last.map { Date(timeIntervalSince1970: $0) })
}

@Suite("ConnectionList")
struct ConnectionListTests {
    @Test func upsertAddsThenReplacesBySameID() {
        var list = ConnectionList()
        let id = UUID()
        list.upsert(connection("A", id: id))
        list.upsert(connection("B"))
        list.upsert(connection("A đã đổi tên", id: id))
        #expect(list.items.count == 2)
        #expect(list.items.first { $0.id == id }?.name == "A đã đổi tên")
    }

    @Test func removeDeletesOnlyThatOne() {
        var list = ConnectionList()
        let id = UUID()
        list.upsert(connection("A", id: id))
        list.upsert(connection("B"))
        list.remove(id: id)
        #expect(list.items.map(\.name) == ["B"])
        list.remove(id: UUID()) // id không có: không làm gì
        #expect(list.items.count == 1)
    }

    @Test func markUsedUpdatesOnlyThatOneAndIgnoresUnknownIDs() {
        var list = ConnectionList()
        let id = UUID()
        list.upsert(connection("A", id: id))
        list.upsert(connection("B"))
        list.markUsed(id: id, at: Date(timeIntervalSince1970: 100))
        list.markUsed(id: UUID(), at: Date(timeIntervalSince1970: 999))
        #expect(list.items.first { $0.id == id }?.lastUsed == Date(timeIntervalSince1970: 100))
        #expect(list.items.first { $0.name == "B" }?.lastUsed == nil)
    }

    @Test func sortsMostRecentFirstThenUnusedByName() {
        let list = ConnectionList([
            connection("Zeta"), connection("Alpha"), connection("Cũ", last: 10), connection("Mới", last: 20),
        ])
        #expect(list.sorted.map(\.name) == ["Mới", "Cũ", "Alpha", "Zeta"])
    }

    @Test func sortIsStableForEqualTimesByName() {
        let list = ConnectionList([connection("B", last: 5), connection("A", last: 5)])
        #expect(list.sorted.map(\.name) == ["A", "B"])
    }

    @Test func nameOrderIgnoresCaseAndDiacritics() {
        let list = ConnectionList([connection("bình"), connection("Anh"), connection("Binh2")])
        // localizedStandardCompare: "Anh" < "bình" < "Binh2"? Chỉ kiểm điều chắc chắn: Anh đứng đầu.
        #expect(list.sorted.first?.name == "Anh")
    }

    @Test func detailShowsPortOnlyWhenNotDefault() {
        #expect(SavedConnection(name: "n", target: .host("mac.local", port: 5900), username: "").detail == "mac.local")
        #expect(SavedConnection(name: "n", target: .host("mac.local", port: 5901), username: "").detail == "mac.local:5901")
        #expect(SavedConnection(name: "n", target: .bonjour(name: "Mac mini", type: "_rfb._tcp", domain: "local."), username: "").detail == "Mac mini")
    }
}

@Suite("ConnectionStore")
struct ConnectionStoreTests {
    private func makeStore() -> (ConnectionStore, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ConnectionStoreTests-\(UUID().uuidString)")
        return (ConnectionStore(fileURL: directory.appendingPathComponent("connections.json")), directory)
    }

    @Test func missingFileLoadsAsEmpty() {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(store.load() == ConnectionList())
    }

    @Test func roundTripPreservesEverythingIncludingBothTargetKinds() throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let list = ConnectionList([
            SavedConnection(name: "Mac mini", target: .host("192.168.1.5", port: 5900), username: "alice",
                            lastUsed: Date(timeIntervalSince1970: 1_700_000_000)),
            SavedConnection(name: "Phòng làm việc", target: .bonjour(name: "Mac-mini", type: "_rfb._tcp", domain: "local."), username: "đ"),
        ])
        try store.save(list)
        #expect(store.load() == list)
    }

    @Test func corruptFileIsBackedUpNotDeleted() throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{ không phải JSON".utf8).write(to: store.fileURL)

        #expect(store.load() == ConnectionList())
        #expect(!FileManager.default.fileExists(atPath: store.fileURL.path), "file hỏng phải được dời đi")
        let backups = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.contains("corrupt") }
        #expect(backups.count == 1, "phải còn bản sao lưu để người dùng khôi phục")
        let kept = try String(contentsOf: directory.appendingPathComponent(backups[0]), encoding: .utf8)
        #expect(kept == "{ không phải JSON")
    }

    @Test func saveCreatesMissingDirectoriesAndNeverStoresPasswords() throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try store.save(ConnectionList([connection("A")]))
        let text = try String(contentsOf: store.fileURL, encoding: .utf8)
        #expect(!text.lowercased().contains("password"))
    }
}

@Suite("InMemorySecretStore")
struct SecretStoreTests {
    @Test func setReadReplaceRemove() throws {
        let store = InMemorySecretStore()
        let id = UUID()
        #expect(try store.password(for: id) == nil)
        try store.setPassword("một", for: id)
        try store.setPassword("hai", for: id)
        #expect(try store.password(for: id) == "hai")
        try store.removePassword(for: id)
        #expect(try store.password(for: id) == nil)
    }

    @Test func secretsAreSeparatePerConnection() throws {
        let store = InMemorySecretStore()
        let a = UUID(), b = UUID()
        try store.setPassword("a", for: a)
        try store.setPassword("b", for: b)
        try store.removePassword(for: a)
        #expect(try store.password(for: b) == "b")
    }
}

@Suite("ConnectionDraft")
struct ConnectionDraftTests {
    private func validate(_ host: String, _ port: String = "5900") -> Result<ConnectionDraft.Validated, ConnectionDraft.Problem> {
        ConnectionDraft(host: host, port: port).validated()
    }

    @Test func plainHostAndPort() {
        #expect(validate("mac-mini.local") == .success(.init(host: "mac-mini.local", port: 5900)))
        #expect(validate("  192.168.1.5  ", " 5901 ") == .success(.init(host: "192.168.1.5", port: 5901)))
    }

    @Test func emptyHostIsAnErrorEvenWithWhitespace() {
        #expect(validate("") == .failure(.emptyHost))
        #expect(validate("   \n") == .failure(.emptyHost))
        #expect(validate("vnc://") == .failure(.emptyHost))
    }

    /// Cổng gõ sai phải báo lỗi, không được lặng lẽ đổi về 5900.
    @Test(arguments: ["59OO", "abc", "0", "65536", "-1", "5900.5", "99999999999"])
    func invalidPortsAreErrors(port: String) {
        #expect(validate("mac.local", port) == .failure(.invalidPort))
    }

    @Test func emptyPortMeansDefault() {
        #expect(validate("mac.local", "") == .success(.init(host: "mac.local", port: 5900)))
    }

    @Test func boundaryPorts() {
        #expect(validate("h", "1") == .success(.init(host: "h", port: 1)))
        #expect(validate("h", "65535") == .success(.init(host: "h", port: 65535)))
    }

    @Test func pastedVNCURLIsUnpacked() {
        #expect(validate("vnc://mac.local") == .success(.init(host: "mac.local", port: 5900)))
        #expect(validate("VNC://mac.local:5901/") == .success(.init(host: "mac.local", port: 5901)))
        // Tên tài khoản không thuộc địa chỉ nhưng được giữ lại để điền sẵn vào hộp thoại đăng nhập.
        #expect(validate("vnc://alice@mac.local:5902") == .success(.init(host: "mac.local", port: 5902, username: "alice")))
    }

    @Test func hostColonPortIsSplitButIPv6IsLeftAlone() {
        #expect(validate("mac.local:5903") == .success(.init(host: "mac.local", port: 5903)))
        #expect(validate("fe80::1") == .success(.init(host: "fe80::1", port: 5900)))
    }

    @Test func badPortInsideHostFieldIsStillAnError() {
        #expect(validate("mac.local:abc") == .failure(.invalidPort))
    }
}
