import Foundation
import Testing
@testable import ConnectionKit

@Suite("ComputerList: ghép máy đã lưu với máy trong mạng")
struct ComputerListTests {
    private let mini = DiscoveredHost(name: "Mac mini")
    private let studio = DiscoveredHost(name: "Mac Studio")

    private func saved(_ name: String, target: SavedConnection.Target, user: String = "cuong") -> SavedConnection {
        SavedConnection(name: name, target: target, username: user)
    }

    @Test func aSavedMachineIsNotListedAgainAsNearby() {
        let list = [saved("Mac mini", target: mini.target)]
        let sections = ComputerList.sections(saved: list, discovered: [mini, studio])
        #expect(sections.saved.map(\.name) == ["Mac mini"])
        #expect(sections.nearby.map(\.name) == ["Mac Studio"])
    }

    @Test func savedMachineSeenOnTheNetworkIsMarkedOnline() {
        let sections = ComputerList.sections(saved: [saved("Mac mini", target: mini.target)], discovered: [mini])
        #expect(sections.saved.first?.isOnline == true)
    }

    @Test func savedMachineNotSeenIsNotClaimedOffline() {
        // Không thấy trên Bonjour chỉ là "chưa biết": máy có thể đang bật nhưng ở mạng khác.
        let sections = ComputerList.sections(saved: [saved("Mac mini", target: mini.target)], discovered: [])
        #expect(sections.saved.first?.isOnline == false)
        #expect(sections.saved.count == 1, "máy đã lưu vẫn phải hiện dù không thấy trong mạng")
    }

    @Test func machineSavedByAddressIsNeverMatchedToABonjourService() {
        // Tên máy trùng nhưng đích khác loại: không được suy ra là cùng một máy.
        let byAddress = saved("Mac mini", target: .host("Mac mini", port: 5900))
        let sections = ComputerList.sections(saved: [byAddress], discovered: [mini])
        #expect(sections.saved.first?.isOnline == false)
        #expect(sections.nearby.map(\.name) == ["Mac mini"])
    }

    @Test func savedOrderIsKept() {
        let a = saved("B", target: .host("b", port: 5900))
        let b = saved("A", target: .host("a", port: 5900))
        #expect(ComputerList.sections(saved: [a, b], discovered: []).saved.map(\.name) == ["B", "A"])
    }

    @Test func subtitlesTellWhatToExpect() {
        let sections = ComputerList.sections(
            saved: [saved("Văn phòng", target: .host("10.0.0.2", port: 5901), user: "an")], discovered: [studio]
        )
        #expect(sections.saved.first?.subtitle == "an@10.0.0.2:5901")
        #expect(sections.nearby.first?.subtitle == "Chia sẻ màn hình")
    }

    @Test func emptyInputsGiveEmptySections() {
        #expect(ComputerList.sections(saved: [], discovered: []).isEmpty)
    }

    @Test func rowsHaveDistinctIdentitiesEvenWhenNamesCollide() {
        let one = saved("Mac mini", target: .host("a", port: 5900))
        let two = saved("Mac mini", target: .host("b", port: 5900))
        let ids = ComputerList.sections(saved: [one, two], discovered: [mini]).saved.map(\.id)
        #expect(Set(ids).count == 2)
    }
}

@Suite("ConnectionDraft: tài khoản trong địa chỉ")
struct ConnectionDraftUserTests {
    private func validate(_ host: String) -> ConnectionDraft.Validated? {
        try? ConnectionDraft(host: host).validated().get()
    }

    @Test func userInAddressIsReturnedForPrefill() {
        #expect(validate("cuong@mac-mini.local")?.username == "cuong")
        #expect(validate("vnc://cuong@mac-mini.local:5901") == .init(host: "mac-mini.local", port: 5901, username: "cuong"))
    }

    @Test func plainAddressHasNoUser() {
        #expect(validate("mac-mini.local")?.username == nil)
        #expect(validate("@mac-mini.local")?.username == nil, "@ lẻ không tạo ra tên rỗng")
    }
}

@MainActor
@Suite("ConnectionsModel.connection(for:)")
struct ConnectionForTargetTests {
    @Test func returnsTheMostRecentlyUsedAccountForATarget() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CFT-\(UUID().uuidString)")
        let model = ConnectionsModel(store: ConnectionStore(fileURL: directory.appendingPathComponent("c.json")), secrets: InMemorySecretStore())
        let target = DiscoveredHost(name: "Mac mini").target
        let older = SavedConnection(name: "Mac mini", target: target, username: "cũ")
        let newer = SavedConnection(name: "Mac mini", target: target, username: "mới")
        try model.save(older, password: "a")
        try model.save(newer, password: "b")
        model.markUsed(older, at: Date(timeIntervalSince1970: 100))
        model.markUsed(newer, at: Date(timeIntervalSince1970: 200))
        #expect(model.connection(for: target)?.username == "mới")
        #expect(model.connection(for: .host("khác", port: 5900)) == nil)
    }
}

@Suite("ConnectionDraft: audit địa chỉ")
struct ConnectionDraftAuditTests {
    private func validate(_ host: String) -> ConnectionDraft.Validated? { try? ConnectionDraft(host: host).validated().get() }

    @Test func passwordInTheURLNeverReachesTheUsernameField() {
        let parsed = validate("vnc://alice:s3cret@mac.local")
        #expect(parsed?.username == "alice")
        #expect(parsed?.host == "mac.local")
    }

    @Test func bracketedIPv6WithAndWithoutPort() {
        #expect(validate("[fe80::1]:5901") == .init(host: "fe80::1", port: 5901))
        #expect(validate("[fe80::1]") == .init(host: "fe80::1", port: 5900))
        #expect(validate("vnc://cuong@[fe80::1]:5902")?.port == 5902)
        #expect(validate("[fe80::1]rác") == nil)
    }

    @Test func bareIPv6IsStillLeftAlone() {
        #expect(validate("fe80::1") == .init(host: "fe80::1", port: 5900))
    }
}
