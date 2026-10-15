#if os(macOS)
import Foundation
import LinkProtocol
import Testing
@testable import HelperCore

// MARK: Fakes

actor FakeDisplayStage: DisplayStage {
    var real = [StageDisplay(id: StageDisplayID(rawValue: 1), frame: LinkRect(x: 0, y: 0, width: 1440, height: 900), isVirtual: false)]
    var virtual: [StageDisplay] = []
    var failCreate = false
    private(set) var createCount = 0
    private(set) var removeCount = 0
    private var nextID: UInt32 = 100

    func setFailCreate(_ value: Bool) { failCreate = value }

    func createDisplay(_ spec: VirtualDisplaySpec) async throws -> StageDisplay {
        if failCreate { throw StageError.stageUnavailable("fake") }
        createCount += 1
        nextID += 1
        let display = StageDisplay(
            id: StageDisplayID(rawValue: nextID),
            frame: LinkRect(x: 1440, y: 0, width: Double(spec.width), height: Double(spec.height)), isVirtual: true
        )
        virtual.append(display)
        return display
    }

    func removeDisplay(_ id: StageDisplayID) async throws {
        guard virtual.contains(where: { $0.id == id }) else { throw StageError.unknownDisplay }
        removeCount += 1
        virtual.removeAll { $0.id == id }
    }

    func displays() async -> [StageDisplay] { real + virtual }
    func frame(of display: StageDisplayID) async -> LinkRect? { (real + virtual).first { $0.id == display }?.frame }
    /// A crashed helper's virtual display disappears with it.
    func dropVirtualDisplays() { virtual = [] }
}

actor FakeFrames: WindowFrameSetter {
    var frames: [StageWindowKey: LinkRect] = [:]
    var limits: [StageWindowKey: StageSizeLimits] = [:]
    private(set) var setCalls: [(StageWindowKey, LinkRect)] = []
    private(set) var fullScreenExits: [StageWindowKey] = []
    /// Called before each `setFrame` takes effect.
    var beforeSet: (@Sendable (StageWindowKey) async -> Void)?

    func add(_ key: StageWindowKey, _ frame: LinkRect, limits: StageSizeLimits? = nil) {
        frames[key] = frame
        if let limits { self.limits[key] = limits }
    }
    func remove(_ key: StageWindowKey) { frames[key] = nil }
    func setBeforeSet(_ hook: (@Sendable (StageWindowKey) async -> Void)?) { beforeSet = hook }

    func currentFrame(of window: StageWindowKey) async -> LinkRect? { frames[window] }
    func setFrame(_ window: StageWindowKey, to rect: LinkRect) async -> LinkRect? {
        await beforeSet?(window)
        guard frames[window] != nil else { return nil }
        setCalls.append((window, rect))
        // Like a real app, never go below the minimum size.
        var actual = rect
        if let limit = limits[window] {
            actual.size.width = min(max(actual.size.width, limit.minimum.width), limit.maximum.width)
            actual.size.height = min(max(actual.size.height, limit.minimum.height), limit.maximum.height)
        }
        frames[window] = actual
        return actual
    }
    func exitFullScreen(_ window: StageWindowKey) async { fullScreenExits.append(window) }
    func sizeLimits(of window: StageWindowKey) async -> StageSizeLimits { limits[window] ?? .unbounded }
}

actor MemoryJournal: StageJournalStore {
    private(set) var stored: StageJournal?
    private(set) var saveCount = 0
    var failSave = false

    func setFailSave(_ value: Bool) { failSave = value }
    func load() async throws -> StageJournal? { stored }
    func save(_ journal: StageJournal) async throws {
        if failSave { throw StageJournalError.corrupt }
        saveCount += 1
        stored = journal
    }
    func clear() async throws { stored = nil }
}

private let keyA = StageWindowKey(pid: 10, windowNumber: 1)
private let keyB = StageWindowKey(pid: 10, windowNumber: 2)
private let keyC = StageWindowKey(pid: 11, windowNumber: 3)
private let screen = LinkRect(x: 100, y: 50, width: 1000, height: 600)

private func overlaps(_ a: LinkRect, _ b: LinkRect) -> Bool {
    a.origin.x < b.origin.x + b.size.width && b.origin.x < a.origin.x + a.size.width
        && a.origin.y < b.origin.y + b.size.height && b.origin.y < a.origin.y + a.size.height
}

private func inside(_ inner: LinkRect, _ outer: LinkRect) -> Bool {
    inner.origin.x >= outer.origin.x && inner.origin.y >= outer.origin.y
        && inner.origin.x + inner.size.width <= outer.origin.x + outer.size.width
        && inner.origin.y + inner.size.height <= outer.origin.y + outer.size.height
}

// MARK: Layout

@Suite struct StageLayoutTests {
    private func request(_ id: Int, _ w: Double, _ h: Double, min: LinkSize = LinkSize(width: 100, height: 80),
                         max: LinkSize = StageSizeLimits.unbounded.maximum) -> TileRequest {
        TileRequest(id: StageWindowKey(pid: 1, windowNumber: UInt32(id)), desired: LinkSize(width: w, height: h), minimum: min, maximum: max)
    }

    private func assertValid(_ result: TileResult, in bounds: LinkRect) {
        let rects = Array(result.frames.values)
        for rect in rects { #expect(inside(rect, bounds)) }
        for i in rects.indices { for j in rects.indices where i < j { #expect(!overlaps(rects[i], rects[j])) } }
    }

    @Test func placesWindowsInRowsWithoutOverlap() {
        let requests = [request(1, 400, 250), request(2, 400, 250), request(3, 400, 250)]
        let result = StageLayout.tile(requests, in: screen)
        #expect(result.overflow.isEmpty)
        #expect(result.frames.count == 3)
        assertValid(result, in: screen)
        #expect(result.frames[requests[0].id]?.origin == LinkPoint(x: 100, y: 50))
        #expect(result.frames[requests[1].id]?.origin == LinkPoint(x: 508, y: 50))
        #expect(result.frames[requests[2].id]?.origin == LinkPoint(x: 100, y: 308))
    }

    @Test func isDeterministic() {
        let requests = (1...9).map { request($0, Double(150 + $0 * 20), Double(120 + $0 * 10)) }
        let first = StageLayout.tile(requests, in: screen)
        for _ in 0..<5 { #expect(StageLayout.tile(requests, in: screen) == first) }
    }

    @Test func shrinksEverythingUntilItFits() {
        let requests = (1...6).map { request($0, 500, 400) }
        let result = StageLayout.tile(requests, in: screen)
        #expect(result.overflow.isEmpty)
        #expect(result.frames.count == 6)
        assertValid(result, in: screen)
        for rect in result.frames.values { #expect(rect.size.width >= 100 && rect.size.height >= 80) }
    }

    @Test func respectsMinimumAndMaximumSizes() {
        let tooSmall = request(1, 10, 10, min: LinkSize(width: 200, height: 150))
        let tooBig = request(2, 5000, 5000, max: LinkSize(width: 300, height: 250))
        let result = StageLayout.tile([tooSmall, tooBig], in: screen)
        #expect(result.frames[tooSmall.id]?.size == LinkSize(width: 200, height: 150))
        #expect(result.frames[tooBig.id]?.size == LinkSize(width: 300, height: 250))
        assertValid(result, in: screen)
    }

    @Test func aWindowLargerThanTheDisplayIsClampedToIt() {
        let huge = request(1, 5000, 5000)
        let result = StageLayout.tile([huge], in: screen)
        #expect(result.frames[huge.id]?.size == screen.size)
    }

    @Test func windowsThatCannotFitAtTheirMinimumOverflow() {
        let requests = (1...5).map { request($0, 600, 400, min: LinkSize(width: 600, height: 400)) }
        let result = StageLayout.tile(requests, in: screen)
        #expect(!result.overflow.isEmpty)
        #expect(result.frames.count + result.overflow.count == 5)
        assertValid(result, in: screen)
        #expect(result.overflow == Array(requests.suffix(result.overflow.count)).map(\.id))
    }

    @Test func emptyOrInvalidBounds() {
        #expect(StageLayout.tile([], in: screen).frames.isEmpty)
        let result = StageLayout.tile([request(1, 100, 100)], in: LinkRect(x: 0, y: 0, width: 0, height: 0))
        #expect(result.overflow.count == 1)
    }

    @Test func duplicateKeysArePlacedOnce() {
        let result = StageLayout.tile([request(1, 100, 100), request(1, 200, 200)], in: screen)
        #expect(result.frames.count == 1)
    }

    @Test func sizeMatchingClampsToLimits() {
        let limits = StageSizeLimits(minimum: LinkSize(width: 300, height: 200), maximum: LinkSize(width: 1200, height: 800))
        #expect(StageSizeMatching.windowSize(forScene: LinkSize(width: 1024.4, height: 768), limits: limits) == LinkSize(width: 1024, height: 768))
        #expect(StageSizeMatching.windowSize(forScene: LinkSize(width: 50, height: 5000), limits: limits) == LinkSize(width: 300, height: 800))
        let bounded = StageSizeMatching.windowSize(forScene: LinkSize(width: 1100, height: 700), limits: limits, within: LinkSize(width: 900, height: 900))
        #expect(bounded == LinkSize(width: 900, height: 700))
    }
}

// MARK: Stage

@Suite struct StageTests {
    let display = FakeDisplayStage()
    let frames = FakeFrames()
    let journal = MemoryJournal()
    let spec = VirtualDisplaySpec(width: 1600, height: 1000)
    let originalA = LinkRect(x: 50, y: 60, width: 640, height: 480)
    let originalB = LinkRect(x: 700, y: 100, width: 500, height: 400)

    init() async {
        await frames.add(keyA, originalA)
        await frames.add(keyB, originalB)
    }

    private func makeStage(boot: String = "boot-1", debounce: Duration = .milliseconds(20)) -> Stage {
        Stage(display: display, frames: frames, journal: journal, debounce: debounce, bootID: boot)
    }

    @Test func movesWindowsOntoTheVirtualDisplayWithoutOverlap() async throws {
        let stage = makeStage()
        await stage.start(display: spec)
        #expect(await stage.state == .active)
        let a = try await stage.manage(window: 1, key: keyA, sceneSize: LinkSize(width: 800, height: 600))
        let b = try await stage.manage(window: 2, key: keyB, sceneSize: LinkSize(width: 700, height: 500))
        let area = try #require(await stage.virtualDisplay).frame
        #expect(inside(a, area) || a.origin.x >= area.origin.x)
        let finalA = try #require(await frames.frames[keyA])
        let finalB = try #require(await frames.frames[keyB])
        #expect(inside(finalA, area) && inside(finalB, area))
        #expect(!overlaps(finalA, finalB))
        _ = b
    }

    @Test func journalIsWrittenBeforeTheFirstChange() async throws {
        let journal = self.journal
        let seen = SeenFlag()
        await frames.setBeforeSet { key in
            let stored = await journal.stored
            await seen.record(stored?.entries.contains { $0.window == key } == true)
        }
        let stage = makeStage()
        await stage.start(display: spec)
        try await stage.manage(window: 1, key: keyA, sceneSize: LinkSize(width: 800, height: 600))
        #expect(await seen.values == [true])
        let entry = try #require(await journal.stored?.entries.first)
        #expect(entry.window == keyA)
        #expect(entry.frame.rect == originalA)
        #expect(entry.display == StageDisplayID(rawValue: 1))
    }

    @Test func aWindowIsUntouchedWhenTheJournalCannotBeWritten() async throws {
        await journal.setFailSave(true)
        let stage = makeStage()
        await stage.start(display: spec)
        await #expect(throws: Stage.ManageError.journalUnavailable) {
            try await stage.manage(window: 1, key: keyA, sceneSize: LinkSize(width: 800, height: 600))
        }
        #expect(await frames.setCalls.isEmpty)
        #expect(await frames.frames[keyA] == originalA)
        #expect(await stage.managedWindows.isEmpty)
    }

    @Test func unknownWindowIsRejected() async {
        let stage = makeStage()
        await stage.start(display: spec)
        await #expect(throws: Stage.ManageError.windowGone) {
            try await stage.manage(window: 9, key: StageWindowKey(pid: 1, windowNumber: 999), sceneSize: LinkSize(width: 800, height: 600))
        }
        await #expect(throws: Stage.ManageError.invalidSize) {
            try await stage.manage(window: 1, key: keyA, sceneSize: LinkSize(width: .nan, height: 600))
        }
    }

    @Test func endRestoresEveryWindowAndRemovesTheDisplay() async throws {
        let stage = makeStage()
        await stage.start(display: spec)
        try await stage.manage(window: 1, key: keyA, sceneSize: LinkSize(width: 800, height: 600))
        try await stage.manage(window: 2, key: keyB, sceneSize: LinkSize(width: 700, height: 500))
        #expect(await frames.frames[keyA] != originalA)
        await stage.end()
        #expect(await frames.frames[keyA] == originalA)
        #expect(await frames.frames[keyB] == originalB)
        #expect(await journal.stored == nil)
        #expect(await display.removeCount == 1)
        #expect(await stage.state == .inactive)
    }

    @Test func releaseRestoresOnlyThatWindow() async throws {
        let stage = makeStage()
        await stage.start(display: spec)
        try await stage.manage(window: 1, key: keyA, sceneSize: LinkSize(width: 800, height: 600))
        try await stage.manage(window: 2, key: keyB, sceneSize: LinkSize(width: 700, height: 500))
        await stage.release(window: 1)
        #expect(await frames.frames[keyA] == originalA)
        #expect(await frames.frames[keyB] != originalB)
        #expect(await journal.stored?.entries.map(\.window) == [keyB])
    }

    @Test func restoreIsIdempotent() async throws {
        let stage = makeStage()
        await stage.start(display: spec)
        try await stage.manage(window: 1, key: keyA, sceneSize: LinkSize(width: 800, height: 600))
        await stage.restoreAll()
        let calls = await frames.setCalls.count
        await stage.restoreAll()
        await stage.end()
        await stage.end()
        #expect(await frames.setCalls.count == calls)
        #expect(await frames.frames[keyA] == originalA)
        #expect(await journal.stored == nil)
    }

    @Test func restoresAfterASimulatedCrash() async throws {
        let crashed = makeStage()
        await crashed.start(display: spec)
        try await crashed.manage(window: 1, key: keyA, sceneSize: LinkSize(width: 800, height: 600))
        try await crashed.manage(window: 2, key: keyB, sceneSize: LinkSize(width: 700, height: 500))
        // kill -9: no end(); the virtual display dies with the process.
        await display.dropVirtualDisplays()
        #expect(await frames.frames[keyA] != originalA)

        let relaunched = makeStage()
        await relaunched.recoverFromCrash()
        #expect(await frames.frames[keyA] == originalA)
        #expect(await frames.frames[keyB] == originalB)
        #expect(await journal.stored == nil)
    }

    @Test func startRecoversBeforeCreatingTheDisplay() async throws {
        let crashed = makeStage()
        await crashed.start(display: spec)
        try await crashed.manage(window: 1, key: keyA, sceneSize: LinkSize(width: 800, height: 600))
        let next = makeStage()
        await next.start(display: spec)
        #expect(await frames.frames[keyA] == originalA)
        #expect(await next.state == .active)
    }

    @Test func aJournalFromAnotherBootIsDiscardedNotApplied() async throws {
        let before = makeStage(boot: "boot-1")
        await before.start(display: spec)
        try await before.manage(window: 1, key: keyA, sceneSize: LinkSize(width: 800, height: 600))
        let moved = await frames.frames[keyA]
        let after = makeStage(boot: "boot-2")
        await after.recoverFromCrash()
        #expect(await frames.frames[keyA] == moved)
        #expect(await journal.stored == nil)
    }

    @Test func aWindowThatIsGoneIsSkippedOnRestore() async throws {
        let stage = makeStage()
        await stage.start(display: spec)
        try await stage.manage(window: 1, key: keyA, sceneSize: LinkSize(width: 800, height: 600))
        await frames.remove(keyA)
        await stage.end()
        #expect(await journal.stored == nil)
    }

    @Test func aSavedFrameOnAMissingDisplayIsBroughtBackOnScreen() async throws {
        let offscreen = StageWindowKey(pid: 20, windowNumber: 50)
        await frames.add(offscreen, LinkRect(x: 3000, y: 100, width: 400, height: 300))
        await journal.seed(StageJournal(bootID: "boot-1", entries: [
            .init(window: offscreen, frame: StageFrame(LinkRect(x: 3000, y: 100, width: 400, height: 300)), display: StageDisplayID(rawValue: 77)),
        ]))
        let stage = makeStage()
        await stage.recoverFromCrash()
        let restored = try #require(await frames.frames[offscreen])
        #expect(inside(restored, LinkRect(x: 0, y: 0, width: 1440, height: 900)))
    }

    @Test func requestsAreDebouncedIntoOneChange() async throws {
        let stage = makeStage(debounce: .milliseconds(40))
        await stage.start(display: spec)
        try await stage.manage(window: 1, key: keyA, sceneSize: LinkSize(width: 800, height: 600))
        let before = await frames.setCalls.count
        for width in stride(from: 810.0, through: 900.0, by: 10) {
            await stage.requestSize(window: 1, sceneSize: LinkSize(width: width, height: 600))
        }
        await stage.settle()
        let calls = await frames.setCalls.dropFirst(before)
        #expect(calls.count == 1)
        #expect(calls.first?.1.size == LinkSize(width: 900, height: 600))
    }

    @Test func requestedSizeIsClampedToTheWindowLimits() async throws {
        let limited = StageWindowKey(pid: 30, windowNumber: 70)
        await frames.add(limited, LinkRect(x: 0, y: 0, width: 400, height: 300),
                         limits: StageSizeLimits(minimum: LinkSize(width: 300, height: 200), maximum: LinkSize(width: 700, height: 500)))
        let stage = makeStage()
        await stage.start(display: spec)
        let result = try await stage.manage(window: 5, key: limited, sceneSize: LinkSize(width: 2000, height: 100))
        #expect(result.size == LinkSize(width: 700, height: 200))
    }

    @Test func withoutAStageWindowsAreResizedInPlace() async throws {
        await display.setFailCreate(true)
        let stage = makeStage()
        await stage.start(display: spec)
        #expect(await stage.state == .unavailable)
        try await stage.manage(window: 1, key: keyA, sceneSize: LinkSize(width: 800, height: 600))
        let moved = try #require(await frames.frames[keyA])
        #expect(moved.origin == originalA.origin)
        #expect(moved.size == LinkSize(width: 800, height: 600))
        await stage.end()
        #expect(await frames.frames[keyA] == originalA)
    }

    @Test func disablingTheStageKeepsItInactive() async {
        let stage = makeStage()
        await stage.start(display: nil)
        #expect(await stage.state == .inactive)
        #expect(await display.createCount == 0)
    }

    @Test func stateChangesAreReported() async {
        let states = SeenStates()
        let stage = Stage(display: display, frames: frames, journal: journal, bootID: "boot-1", onState: { states.add($0) })
        await stage.start(display: spec)
        await stage.end()
        #expect(states.values == [.preparing, .active, .inactive])
    }

    @Test func fullScreenExitIsForwarded() async throws {
        let stage = makeStage()
        await stage.start(display: spec)
        try await stage.manage(window: 1, key: keyA, sceneSize: LinkSize(width: 800, height: 600))
        await stage.exitFullScreen(window: 1)
        await stage.exitFullScreen(window: 42)
        #expect(await frames.fullScreenExits == [keyA])
    }

    @Test func hundredCreateAndRemoveCycles() async throws {
        for _ in 0..<100 {
            let stage = makeStage()
            await stage.start(display: spec)
            try await stage.manage(window: 1, key: keyA, sceneSize: LinkSize(width: 800, height: 600))
            await stage.end()
        }
        #expect(await display.createCount == 100)
        #expect(await display.removeCount == 100)
        #expect(await display.virtual.isEmpty)
        #expect(await frames.frames[keyA] == originalA)
    }
}

actor SeenFlag {
    private(set) var values: [Bool] = []
    func record(_ value: Bool) { values.append(value) }
}

final class SeenStates: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [LinkStageState] = []
    var values: [LinkStageState] { lock.withLock { _values } }
    func add(_ state: LinkStageState) { lock.withLock { _values.append(state) } }
}

extension MemoryJournal {
    func seed(_ journal: StageJournal) async { try? await save(journal) }
}

// MARK: Journal file

@Suite struct FileStageJournalStoreTests {
    private func temp() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "screon-journal-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func roundTripsAndClears() async throws {
        let dir = try temp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FileStageJournalStore(url: dir.appending(path: "sub/stage-journal.json"))
        #expect(try await store.load() == nil)
        let journal = StageJournal(bootID: "b", entries: [
            .init(window: keyA, frame: StageFrame(LinkRect(x: 1, y: 2, width: 3, height: 4)), display: StageDisplayID(rawValue: 1)),
        ])
        try await store.save(journal)
        #expect(try await store.load() == journal)
        let attributes = try FileManager.default.attributesOfItem(atPath: store.url.path)
        #expect((attributes[.posixPermissions] as? Int) == 0o600)
        try await store.clear()
        try await store.clear()
        #expect(try await store.load() == nil)
    }

    @Test func rejectsCorruptAndOversizedFiles() async throws {
        let dir = try temp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "j.json")
        let store = FileStageJournalStore(url: url)
        try Data("not json".utf8).write(to: url)
        await #expect(throws: StageJournalError.corrupt) { try await store.load() }
        try Data(repeating: 0x20, count: (1 << 20) + 1).write(to: url)
        await #expect(throws: StageJournalError.tooLarge) { try await store.load() }
        let bad = #"{"version":1,"bootID":"b","entries":[{"window":{"pid":1,"windowNumber":1},"frame":{"x":1e30,"y":0,"width":1,"height":1}}]}"#
        try Data(bad.utf8).write(to: url)
        await #expect(throws: StageJournalError.corrupt) { try await store.load() }
    }

    @Test func aCorruptJournalDoesNotStopTheStage() async throws {
        let dir = try temp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "j.json")
        try Data("garbage".utf8).write(to: url)
        let stage = Stage(display: FakeDisplayStage(), frames: FakeFrames(), journal: FileStageJournalStore(url: url), bootID: "b")
        await stage.start(display: nil)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}
#endif
