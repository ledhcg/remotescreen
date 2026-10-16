#if os(macOS)
import Foundation
import LinkProtocol
import Testing
@testable import HelperCore

/// A menu bar as plain data.
struct FakeMenu: Sendable {
    var title: String
    var enabled = true
    var mark = ""
    var cmd = ""
    var mods = 0
    var separator = false
    var children: [FakeMenu] = []
    var failsToRead = false
}

final class FakeMenuSystem: MenuSystem, @unchecked Sendable {
    private let lock = NSLock()
    private var _bar: [FakeMenu]
    private var generation: UInt64 = 0
    /// id -> path of indices
    private var paths: [UInt64: [Int]] = [:]
    private var nextID: UInt64 = 1
    private var _pressed: [[Int]] = []
    private var _rootReads = 0
    private var _childReads = 0

    init(_ bar: [FakeMenu]) { _bar = bar }

    var bar: [FakeMenu] { get { lock.withLock { _bar } } set { lock.withLock { _bar = newValue } } }
    var pressed: [[Int]] { lock.withLock { _pressed } }
    var rootReads: Int { lock.withLock { _rootReads } }
    var childReads: Int { lock.withLock { _childReads } }

    private func node(at path: [Int]) -> FakeMenu? {
        var items = _bar
        var found: FakeMenu?
        for index in path {
            guard index < items.count else { return nil }
            found = items[index]
            items = items[index].children
        }
        return found
    }

    private func infos(_ items: [FakeMenu], parent: [Int], pid: Int32) -> [MenuNodeInfo] {
        items.enumerated().map { index, item in
            let id = nextID
            nextID += 1
            paths[id] = parent + [index]
            return MenuNodeInfo(
                ref: MenuNodeRef(pid: pid, generation: generation, id: id), title: item.title, isEnabled: item.enabled, markChar: item.mark,
                cmdChar: item.cmd, cmdModifiers: item.mods, isSeparator: item.separator, hasSubmenu: !item.children.isEmpty)
        }
    }

    func rootItems(pid: Int32) async throws -> [MenuNodeInfo] {
        lock.withLock {
            _rootReads += 1
            generation += 1
            paths = [:]
            return infos(_bar, parent: [], pid: pid)
        }
    }

    func children(of ref: MenuNodeRef) async throws -> [MenuNodeInfo] {
        try lock.withLock {
            _childReads += 1
            guard ref.generation == generation, let path = paths[ref.id], let item = node(at: path) else { throw MenuSystemError.staleReference }
            if item.failsToRead { throw MenuSystemError.timeout }
            return infos(item.children, parent: path, pid: ref.pid)
        }
    }

    func press(_ ref: MenuNodeRef) async throws {
        try lock.withLock {
            guard ref.generation == generation, let path = paths[ref.id] else { throw MenuSystemError.staleReference }
            _pressed.append(path)
        }
    }
}

@Suite(.timeLimit(.minutes(2))) struct MenuReaderTests {
    static func sample() -> [FakeMenu] {
        [
            FakeMenu(title: "Apple", children: [FakeMenu(title: "About This Mac")]),
            FakeMenu(title: "File", children: [
                FakeMenu(title: "New", cmd: "N"),
                FakeMenu(title: "Open Recent", children: [FakeMenu(title: "doc1"), FakeMenu(title: "Clear Menu", enabled: false)]),
                FakeMenu(title: "", enabled: false, separator: true),
                FakeMenu(title: "Save As…", cmd: "S", mods: 1),
                FakeMenu(title: "Close", cmd: "W"),
            ]),
            FakeMenu(title: "View", children: [
                FakeMenu(title: "Show Toolbar", mark: "✓", cmd: "T", mods: 2 | 1),
                FakeMenu(title: "Enter Full Screen", cmd: "F", mods: 4),
                FakeMenu(title: "Escape", cmd: "\u{1B}", mods: 8),
            ]),
        ]
    }

    // MARK: Reading

    @Test func convertsTitlesStatesAndKeyEquivalents() async throws {
        let reader = MenuReader(system: FakeMenuSystem(Self.sample()))
        let tree = try await reader.tree(pid: 1)
        #expect(tree.map(\.title) == ["Apple", "File", "View"])

        let file = tree[1].children
        #expect(file.map(\.title) == ["New", "Open Recent", "", "Save As…", "Close"])
        #expect(file[0].keyEquivalent == "N" && file[0].modifiers == [.command])
        #expect(file[1].children.map(\.title) == ["doc1", "Clear Menu"])
        #expect(file[1].children[1].enabled == false)
        #expect(file[2].isSeparator && file[2].title.isEmpty && !file[2].enabled)
        #expect(file[3].modifiers == [.command, .shift])

        let view = tree[2].children
        #expect(view[0].checked && view[0].modifiers == [.command, .option, .shift])
        #expect(!view[1].checked && view[1].modifiers == [.command, .control])
        #expect(view[2].modifiers == [], "the no-command bit removes the command modifier")
    }

    @Test func itemsWithoutAShortcutHaveNoModifiers() {
        let item = MenuReader.convert(MenuNodeInfo(
            ref: MenuNodeRef(pid: 1, generation: 1, id: 1), title: "Plain", cmdChar: "", cmdModifiers: 0))
        #expect(item.keyEquivalent.isEmpty && item.modifiers.isEmpty)
    }

    @Test func titlesAndKeyEquivalentsAreBounded() async throws {
        let long = String(repeating: "é", count: 400)
        let reader = MenuReader(system: FakeMenuSystem([FakeMenu(title: long, children: [FakeMenu(title: "x", cmd: String(repeating: "k", count: 100))])]))
        let tree = try await reader.tree(pid: 1)
        #expect(tree[0].title.utf8.count <= LinkLimits.maxMenuTitleBytes)
        #expect(tree[0].children[0].keyEquivalent.utf8.count <= LinkLimits.maxKeyEquivalentBytes)
    }

    @Test func depthIsBounded() async throws {
        var deepest = FakeMenu(title: "level 12")
        for level in stride(from: 11, through: 1, by: -1) { deepest = FakeMenu(title: "level \(level)", children: [deepest]) }
        let system = FakeMenuSystem([deepest])
        let tree = try await MenuReader(system: system).tree(pid: 1)
        func depth(_ items: [LinkMenuItem]) -> Int { items.isEmpty ? 0 : 1 + (items.map { depth($0.children) }.max() ?? 0) }
        #expect(depth(tree) == LinkLimits.maxMenuDepth)
        // The reader stopped asking: root read + 5 child reads.
        #expect(system.childReads == LinkLimits.maxMenuDepth - 1)
    }

    @Test func itemsPerLevelAreBounded() async throws {
        let wide = (0..<(LinkLimits.maxMenuItemsPerLevel + 100)).map { FakeMenu(title: "item \($0)") }
        let tree = try await MenuReader(system: FakeMenuSystem([FakeMenu(title: "Big", children: wide)])).tree(pid: 1)
        #expect(tree[0].children.count == LinkLimits.maxMenuItemsPerLevel)
        let wideRoot = (0..<(LinkLimits.maxMenuItemsPerLevel + 1)).map { FakeMenu(title: "root \($0)") }
        #expect(try await MenuReader(system: FakeMenuSystem(wideRoot)).tree(pid: 1).count == LinkLimits.maxMenuItemsPerLevel)
    }

    @Test func totalItemsAreBounded() async throws {
        let menus = (0..<20).map { m in FakeMenu(title: "m\(m)", children: (0..<LinkLimits.maxMenuItemsPerLevel).map { FakeMenu(title: "i\($0)") }) }
        let tree = try await MenuReader(system: FakeMenuSystem(menus)).tree(pid: 1)
        func count(_ items: [LinkMenuItem]) -> Int { items.reduce(0) { $0 + 1 + count($1.children) } }
        #expect(count(tree) <= LinkLimits.maxMenuItemsTotal)
        #expect(count(tree) == LinkLimits.maxMenuItemsTotal)
    }

    @Test func oneUnreadableSubmenuDoesNotHideTheRest() async throws {
        var bar = Self.sample()
        bar[1].children[1].failsToRead = true
        let tree = try await MenuReader(system: FakeMenuSystem(bar)).tree(pid: 1)
        #expect(tree[1].children[1].children.isEmpty)
        #expect(tree[2].children.count == 3)
    }

    @Test func permissionErrorsSurface() async {
        struct Denied: MenuSystem {
            func rootItems(pid: Int32) async throws -> [MenuNodeInfo] { throw MenuSystemError.permissionDenied }
            func children(of ref: MenuNodeRef) async throws -> [MenuNodeInfo] { [] }
            func press(_ ref: MenuNodeRef) async throws {}
        }
        await #expect(throws: MenuReaderError.system(.permissionDenied)) { try await MenuReader(system: Denied()).tree(pid: 1) }
    }

    // MARK: Cache

    @Test func cacheIsServedUntilAMenuOrTitleChangeInvalidatesIt() async throws {
        let system = FakeMenuSystem(Self.sample())
        let reader = MenuReader(system: system)
        _ = try await reader.tree(pid: 1)
        let reads = system.rootReads
        _ = try await reader.tree(pid: 1)
        #expect(system.rootReads == reads, "served from the cache")

        for kind in [AXNotificationKind.menuOpened, .titleChanged] {
            await reader.handle(.ax(pid: 1, kind))
            let before = system.rootReads
            _ = try await reader.tree(pid: 1)
            #expect(system.rootReads == before + 1, "\(kind) invalidates")
        }
        // Other apps and other notifications leave it alone.
        await reader.handle(.ax(pid: 2, .menuOpened))
        await reader.handle(.ax(pid: 1, .windowMoved))
        let before = system.rootReads
        _ = try await reader.tree(pid: 1)
        #expect(system.rootReads == before)
    }

    // MARK: Pressing

    @Test func pressResolvesThePathAndPressesTheLiveItem() async throws {
        let system = FakeMenuSystem(Self.sample())
        let reader = MenuReader(system: system)
        _ = try await reader.tree(pid: 1)
        try await reader.press(pid: 1, path: [1, 3])
        try await reader.press(pid: 1, path: [1, 1, 0])
        #expect(system.pressed == [[1, 3], [1, 1, 0]])
    }

    @Test func pressRejectsAChangedTitle() async throws {
        let system = FakeMenuSystem(Self.sample())
        let reader = MenuReader(system: system)
        _ = try await reader.tree(pid: 1)
        system.bar[1].children[3].title = "Save Copy…"
        await #expect(throws: MenuReaderError.stalePath) { try await reader.press(pid: 1, path: [1, 3]) }
        #expect(system.pressed.isEmpty)
    }

    @Test func pressRejectsAShiftedIndexEvenWhenAnotherItemNowSitsThere() async throws {
        let system = FakeMenuSystem(Self.sample())
        let reader = MenuReader(system: system)
        _ = try await reader.tree(pid: 1)
        // An item was inserted above "Close": index 4 now holds a different item.
        system.bar[1].children.insert(FakeMenu(title: "Print"), at: 3)
        await #expect(throws: MenuReaderError.stalePath) { try await reader.press(pid: 1, path: [1, 4]) }
        await #expect(throws: MenuReaderError.stalePath) { try await reader.press(pid: 1, path: [1, 3]) }
        #expect(system.pressed.isEmpty)
    }

    @Test func pressRejectsAnEarlierMenuThatChanged() async throws {
        let system = FakeMenuSystem(Self.sample())
        let reader = MenuReader(system: system)
        _ = try await reader.tree(pid: 1)
        system.bar[1].title = "Datei"
        await #expect(throws: MenuReaderError.stalePath) { try await reader.press(pid: 1, path: [1, 0]) }
    }

    @Test func pressRejectsOutOfRangeAndUnseenPaths() async throws {
        let system = FakeMenuSystem(Self.sample())
        let reader = MenuReader(system: system)
        await #expect(throws: MenuReaderError.stalePath) { try await reader.press(pid: 1, path: [0, 0]) }  // never sent a tree
        _ = try await reader.tree(pid: 1)
        await #expect(throws: MenuReaderError.stalePath) { try await reader.press(pid: 1, path: [9]) }
        await #expect(throws: MenuReaderError.stalePath) { try await reader.press(pid: 1, path: [1, 99]) }
        await #expect(throws: MenuReaderError.stalePath) { try await reader.press(pid: 1, path: [0, 0, 0]) }  // "About" has no submenu
        await #expect(throws: MenuReaderError.stalePath) { try await reader.press(pid: 2, path: [0, 0]) }  // other app
        #expect(system.pressed.isEmpty)
    }

    @Test func pressRejectsInvalidPaths() async throws {
        let reader = MenuReader(system: FakeMenuSystem(Self.sample()))
        _ = try await reader.tree(pid: 1)
        await #expect(throws: MenuReaderError.invalidPath) { try await reader.press(pid: 1, path: []) }
        await #expect(throws: MenuReaderError.invalidPath) { try await reader.press(pid: 1, path: [UInt16](repeating: 0, count: LinkLimits.maxMenuDepth + 1)) }
    }

    @Test func pressRefusesSeparatorsDisabledItemsAndSubmenus() async throws {
        let system = FakeMenuSystem(Self.sample())
        let reader = MenuReader(system: system)
        _ = try await reader.tree(pid: 1)
        await #expect(throws: MenuReaderError.notPressable) { try await reader.press(pid: 1, path: [1, 2]) }
        await #expect(throws: MenuReaderError.notPressable) { try await reader.press(pid: 1, path: [1, 1, 1]) }
        await #expect(throws: MenuReaderError.notPressable) { try await reader.press(pid: 1, path: [1, 1]) }
        #expect(system.pressed.isEmpty)
    }

    @Test func invalidationDoesNotMakeAValidPressStale() async throws {
        let system = FakeMenuSystem(Self.sample())
        let reader = MenuReader(system: system)
        _ = try await reader.tree(pid: 1)
        await reader.handle(.ax(pid: 1, .menuOpened))   // the user opened a menu on the Mac
        try await reader.press(pid: 1, path: [1, 0])
        #expect(system.pressed == [[1, 0]])
    }

    @Test func terminatedAppIsForgotten() async throws {
        let reader = MenuReader(system: FakeMenuSystem(Self.sample()))
        _ = try await reader.tree(pid: 1)
        await reader.handle(.appTerminated(pid: 1))
        await #expect(throws: MenuReaderError.stalePath) { try await reader.press(pid: 1, path: [1, 0]) }
    }
}

/// Real accessibility checks. They need the Accessibility permission and a logged-in Mac, so they only run when asked:
/// `SCREON_AX_TESTS=1 swift test --filter RealAccessibilitySmokeTests`.
@Suite(.timeLimit(.minutes(2)), .enabled(if: ProcessInfo.processInfo.environment["SCREON_AX_TESTS"] == "1")) struct RealAccessibilitySmokeTests {
    @Test func windowListAndMenuBarOfFinder() async throws {
        let windows = AXWindowSystem()
        #expect(!windows.trackablePIDs().isEmpty)
        #expect(!windows.cgWindows().isEmpty)
        guard let finder = windows.trackablePIDs().first(where: { windows.bundleID(forPID: $0) == "com.apple.finder" }) else { return }
        let menus = MenuReader(system: AXMenuSystem())
        let tree = try await menus.tree(pid: finder)
        #expect(tree.count > 3)
        _ = try await windows.axWindows(pid: finder)
    }
}
#endif
