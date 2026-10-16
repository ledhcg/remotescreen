import Foundation
import LinkProtocol
import Localization
import Testing
@testable import WindowKit

@Suite("Icon cache policy")
struct IconCacheIndexTests {
    private func key(_ n: UInt32, _ size: UInt16 = 128) -> IconCacheKey { IconCacheKey(iconKey: IconKey(n), pixelSize: size) }

    @Test func fileNamesRoundTripAndForeignNamesAreRejected() {
        let k = key(42, 256)
        #expect(k.fileName == "icon-42-256.png")
        #expect(IconCacheKey(fileName: k.fileName) == k)
        for bad in ["icon-1.png", "icon-a-1.png", "icon-1-2-3.png", "../icon-1-2.png", "icon-01-2.png", "icon-1-99999.png", "x.png", ".DS_Store"] {
            #expect(IconCacheKey(fileName: bad) == nil, "\(bad)")
        }
    }

    @Test func pixelBucketsCoverTheRequestedSize() {
        #expect(IconSize.pixels(points: 32, scale: 2) == 64)
        #expect(IconSize.pixels(points: 48, scale: 2) == 128)
        #expect(IconSize.pixels(points: 100, scale: 3) == 256)
        #expect(IconSize.pixels(points: 1000, scale: 3) == 256)
        #expect(IconSize.pixels(points: .nan, scale: 2) == 64)
    }

    @Test func leastRecentlyUsedGoesFirstWhenOverTheByteLimit() {
        var index = IconCacheIndex(limits: .init(maxTotalBytes: 300, maxEntries: 100, maxEntryBytes: 200))
        let r1 = index.insert(key(1), bytes: 100)
        #expect(r1.evicted.isEmpty)
        let r2 = index.insert(key(2), bytes: 100)
        #expect(r2.evicted.isEmpty)
        let r3 = index.insert(key(3), bytes: 100)
        #expect(r3.evicted.isEmpty)
        index.touch(key(1))  // 2 is now the oldest
        let result = index.insert(key(4), bytes: 100)
        #expect(result.accepted)
        #expect(result.evicted == [key(2)])
        #expect(index.totalBytes == 300)
        #expect(!index.contains(key(2)) && index.contains(key(1)))
    }

    @Test func entryCountIsBoundedToo() {
        var index = IconCacheIndex(limits: .init(maxTotalBytes: 10_000, maxEntries: 2, maxEntryBytes: 100))
        _ = index.insert(key(1), bytes: 10)
        _ = index.insert(key(2), bytes: 10)
        let r4 = index.insert(key(3), bytes: 10)
        #expect(r4.evicted == [key(1)])
        #expect(index.count == 2)
    }

    @Test func oversizedAndEmptyIconsAreNotCached() {
        var index = IconCacheIndex(limits: .init(maxTotalBytes: 1000, maxEntries: 10, maxEntryBytes: 100))
        let r5 = index.insert(key(1), bytes: 101)
        #expect(!r5.accepted)
        let r6 = index.insert(key(1), bytes: 0)
        #expect(!r6.accepted)
        #expect(index.count == 0 && index.totalBytes == 0)
    }

    @Test func replacingAnEntryAdjustsTheTotal() {
        var index = IconCacheIndex(limits: .init(maxTotalBytes: 1000, maxEntries: 10, maxEntryBytes: 500))
        _ = index.insert(key(1), bytes: 400)
        _ = index.insert(key(1), bytes: 100)
        #expect(index.totalBytes == 100 && index.count == 1)
        index.remove(key(1))
        #expect(index.totalBytes == 0)
    }

    @Test func rebuildKeepsTheNewestFilesAndDropsTheRest() {
        var index = IconCacheIndex(limits: .init(maxTotalBytes: 200, maxEntries: 10, maxEntryBytes: 150))
        let t0 = Date(timeIntervalSince1970: 1000)
        let dropped = index.rebuild(from: [
            (key(3), 100, t0.addingTimeInterval(30)), (key(1), 100, t0), (key(2), 100, t0.addingTimeInterval(10)),
            (key(9), 500, t0.addingTimeInterval(40)),  // too big
        ])
        #expect(Set(dropped) == [key(9), key(1)])
        #expect(index.contains(key(2)) && index.contains(key(3)) && index.totalBytes == 200)
    }

    @Test func theNewestInsertionSurvivesEvenWhenItIsTheOnlyOneLeft() {
        var index = IconCacheIndex(limits: .init(maxTotalBytes: 100, maxEntries: 10, maxEntryBytes: 100))
        _ = index.insert(key(1), bytes: 60)
        let result = index.insert(key(2), bytes: 100)
        #expect(result.evicted == [key(1)] && index.contains(key(2)))
    }
}

@Suite("Resize debounce and size limits")
struct ResizeDebouncerTests {
    private func size(_ w: Double, _ h: Double) -> LinkSize { LinkSize(width: w, height: h) }

    @Test func theFirstSizeIsOnlyABaseline() {
        var d = ResizeDebouncer()
        d.observe(size(800, 600), at: 0)
        #expect(d.deadline == nil)
        let r7 = d.poll(at: 5, isInteractivelyResizing: false)
        #expect(r7 == nil)
    }

    @Test func aDragSendsOneRequestAfterItSettles() {
        var d = ResizeDebouncer(settleDelay: 0.3)
        d.observe(size(800, 600), at: 0)
        for (i, w) in stride(from: 810.0, through: 900, by: 10).enumerated() { d.observe(size(w, 600), at: 1 + Double(i) * 0.05) }
        let r8 = d.poll(at: 1.3, isInteractivelyResizing: false)
        #expect(r8 == nil)  // last change at 1.45
        let r9 = d.poll(at: 1.8, isInteractivelyResizing: true)
        #expect(r9 == nil)  // still dragging
        let r10 = d.poll(at: 1.8, isInteractivelyResizing: false)
        #expect(r10 == size(900, 600))
        let r11 = d.poll(at: 2.5, isInteractivelyResizing: false)
        #expect(r11 == nil)  // nothing more pending
    }

    @Test func tinyChangesAndReturnToTheSameSizeSendNothing() {
        var d = ResizeDebouncer(settleDelay: 0.1, tolerance: 2)
        d.observe(size(800, 600), at: 0)
        d.observe(size(801, 601), at: 1)
        let r12 = d.poll(at: 2, isInteractivelyResizing: false)
        #expect(r12 == nil)
        d.observe(size(900, 600), at: 3)
        d.observe(size(800, 600), at: 3.05)
        let r13 = d.poll(at: 4, isInteractivelyResizing: false)
        #expect(r13 == nil)
    }

    @Test func invalidSizesAreIgnored() {
        var d = ResizeDebouncer()
        d.observe(size(.nan, 10), at: 0)
        d.observe(size(0, 0), at: 0)
        d.observe(size(-5, 100), at: 0)
        d.observe(size(500, 400), at: 0)  // this is the baseline, so the earlier ones did not count
        d.observe(size(600, 400), at: 1)
        let r14 = d.poll(at: 2, isInteractivelyResizing: false)
        #expect(r14 == size(600, 400))
    }

    @Test func resetBaselineForgetsPendingWork() {
        var d = ResizeDebouncer(settleDelay: 0.1)
        d.observe(size(800, 600), at: 0)
        d.observe(size(900, 600), at: 1)
        d.resetBaseline(to: nil)
        let r15 = d.poll(at: 5, isInteractivelyResizing: false)
        #expect(r15 == nil)
    }

    @Test func limitsClampAndTreatZeroAsNoMaximum() {
        let none = SceneSizeLimits(minSize: size(100, 100), maxSize: size(0, 0))
        #expect(none.minimum == SceneSizeLimits.floor && none.maximum == nil)
        #expect(none.clamp(size(10, 10)) == SceneSizeLimits.floor)
        #expect(none.clamp(size(5000, 4000)) == size(5000, 4000))
        let bounded = SceneSizeLimits(minSize: size(400, 300), maxSize: size(1000, 800))
        #expect(bounded.clamp(size(2000, 100)) == size(1000, 300))
        // A maximum below the minimum is nonsense and is ignored.
        #expect(SceneSizeLimits(minSize: size(400, 300), maxSize: size(200, 200)).maximum == nil)
        #expect(SceneSizeLimits(minSize: size(100_000, 100_000), maxSize: size(0, 0)).minimum == size(4096, 4096))
    }
}

@Suite("Window reference and restoration")
struct WindowRefTests {
    private func ws(_ windows: [LinkWindowInfo]) -> RemoteWorkspace { workspace(windows) }

    @Test func encodesAndDecodesWithItsHint() throws {
        let w = ws([makeWindow(7, bundle: "com.example.notes", title: "Shopping \"list\" é")])
        let ref = try #require(WindowRef(window: 7, in: w))
        let again = try #require(WindowRef(encoded: ref.encoded))
        #expect(again == ref)
        #expect(again.query?.title == "Shopping \"list\" é")
    }

    @Test func plainNumbersFromEarlierVersionsStillWork() {
        let ref = WindowRef(encoded: "12")
        #expect(ref?.windowID == 12 && ref?.query == nil)
    }

    @Test func hostileTextIsRefused() {
        #expect(WindowRef(encoded: "") == nil)
        #expect(WindowRef(encoded: "{}") == nil)
        #expect(WindowRef(encoded: "not json") == nil)
        #expect(WindowRef(encoded: String(repeating: "a", count: 5000)) == nil)
        #expect(WindowRef(encoded: #"{"b":"x","i":-1}"#) == nil)
        #expect(WindowRef(encoded: #"{"b":"x","i":99999999}"#) == nil)
        #expect(WindowRef(encoded: #"{"w":1,"b":"x"}"#) == nil)  // a hint needs its index
    }

    @Test func longTitlesAreCutSoTheReferenceStaysSmall() throws {
        let ref = WindowRef(windowID: 1, query: WindowMatchQuery(bundleID: "a.b", title: String(repeating: "x", count: 10_000), indexHint: 0))
        #expect(ref.encoded.utf8.count <= WindowRef.maxEncodedLength)
        #expect(WindowRef(encoded: ref.encoded)?.query?.title.count == WindowRef.maxTitleLength)
    }

    @Test func aLiveIdThatStillFitsIsKept() {
        let w = ws([makeWindow(1, bundle: "a", title: "One"), makeWindow(2, bundle: "a", title: "Two")])
        let ref = WindowRef(windowID: 2, query: WindowMatchQuery(bundleID: "a", title: "Two", indexHint: 1))
        #expect(ref.start(in: w) == .bind(2))
    }

    @Test func aStaleIdPointingToAnotherWindowIsNotTrusted() {
        // The helper restarted: id 2 now belongs to a different app, and the window we want has another id.
        let w = ws([makeWindow(2, bundle: "other", title: "Two"), makeWindow(5, bundle: "a", title: "Two")])
        let ref = WindowRef(windowID: 2, query: WindowMatchQuery(bundleID: "a", title: "Two", indexHint: 0))
        #expect(ref.start(in: w) == .bind(5))
    }

    @Test func aStaleIdOfTheSameAppButAnotherTitleLosesToABetterMatch() {
        let w = ws([makeWindow(2, bundle: "a", title: "Inbox"), makeWindow(9, bundle: "a", title: "Draft")])
        let ref = WindowRef(windowID: 2, query: WindowMatchQuery(bundleID: "a", title: "Draft", indexHint: 1))
        #expect(ref.start(in: w) == .bind(9))
    }

    @Test func noSnapshotMeansSearchLaterAndNothingMatchingMeansSearch() {
        let query = WindowMatchQuery(bundleID: "a", title: "T", indexHint: 0)
        let ref = WindowRef(windowID: 1, query: query)
        #expect(ref.start(in: RemoteWorkspace()) == .search(query))
        #expect(ref.start(in: ws([makeWindow(1, bundle: "zzz")])) == .search(query))
        #expect(WindowRef(windowID: nil, query: nil).start(in: RemoteWorkspace()) == .nothing)
    }

    @Test func windowsAlreadyShownElsewhereAreSkipped() {
        let w = ws([makeWindow(1, bundle: "a", title: "T"), makeWindow(2, bundle: "a", title: "T")])
        let ref = WindowRef(windowID: 1, query: WindowMatchQuery(bundleID: "a", title: "T", indexHint: 0))
        #expect(ref.start(in: w, excluding: [1]) == .bind(2))
    }

    @Test func revalidateRebindsAfterAHelperRestart() {
        let before = ws([makeWindow(1, bundle: "a", title: "Doc"), makeWindow(2, bundle: "b", title: "Other")])
        var bindings = SceneBindings()
        bindings.open(window: 1, in: SceneID("s1"), workspace: before)
        bindings.open(window: 2, in: SceneID("s2"), workspace: before)
        // After the restart ids start over: id 1 is another app's window, and the notes window is now 7.
        let after = ws([makeWindow(1, bundle: "b", title: "Other"), makeWindow(7, bundle: "a", title: "Doc")])
        let changed = bindings.revalidate(with: after)
        #expect(bindings.state(of: SceneID("s1")) == .bound(7))
        #expect(changed.contains(SceneID("s1")))
    }

    @Test func revalidateLeavesGoodBindingsAloneAndRevivesClosedOnes() {
        let before = ws([makeWindow(1, bundle: "a", title: "Doc"), makeWindow(2, bundle: "b", title: "Gone")])
        var bindings = SceneBindings()
        bindings.open(window: 1, in: SceneID("s1"), workspace: before)
        bindings.open(window: 2, in: SceneID("s2"), workspace: before)
        let during = ws([makeWindow(1, bundle: "a", title: "Doc")])
        bindings.reconcile(with: during)
        #expect(bindings.state(of: SceneID("s2"))?.windowID == nil)
        let after = ws([makeWindow(1, bundle: "a", title: "Doc"), makeWindow(4, bundle: "b", title: "Gone")])
        let changed = bindings.revalidate(with: after)
        #expect(changed == [SceneID("s2")])
        #expect(bindings.state(of: SceneID("s1")) == .bound(1))
        #expect(bindings.state(of: SceneID("s2")) == .bound(4))
    }

    @Test func revalidateWithoutSnapshotDoesNothing() {
        var bindings = SceneBindings()
        bindings.restore(scene: SceneID("s"), query: WindowMatchQuery(bundleID: "a", title: "T", indexHint: 0), workspace: RemoteWorkspace())
        let r16 = bindings.revalidate(with: RemoteWorkspace())
        #expect(r16.isEmpty)
    }
}

@Suite("Launcher listing", .serialized)
struct LauncherTests {
    init() { Localization.forcedLanguage = "en" }

    private func app(_ ref: UInt32, _ bundle: String, _ name: String) -> LinkAppInfo { makeApp(ref, bundle: bundle, name: name) }

    @Test func answersAreMatchedToRequestsInOrder() {
        var dir = AppsDirectory()
        let r17 = dir.willRequest(.recent)
        #expect(r17)
        let r18 = dir.willRequest(.installed)
        #expect(r18)
        let r19 = dir.willRequest(.recent)
        #expect(!r19)  // already on its way
        let r20 = dir.receive([app(1, "a", "A")])
        #expect(r20 == .recent)
        let r21 = dir.receive([app(2, "b", "B"), app(2, "b", "B again")])
        #expect(r21 == .installed)
        #expect(dir.installed.count == 1 && dir.recent.count == 1)
        let r22 = dir.receive([])
        #expect(r22 == nil)  // unsolicited
        #expect(dir.hasLoaded(.recent) && !dir.hasLoaded(.running))
    }

    @Test func tooManyRequestsInFlightAreDroppedAndALostConnectionClearsThem() {
        var dir = AppsDirectory()
        var accepted = 0
        for filter in [LinkAppFilter.running, .recent, .installed] {
            if dir.willRequest(filter) { accepted += 1 }
        }
        #expect(accepted == 3)
        dir.connectionLost()
        let r23 = dir.willRequest(.running)
        #expect(r23)
    }

    @Test func listsAreBoundedToTheProtocolLimit() {
        var dir = AppsDirectory()
        _ = dir.willRequest(.installed)
        let many = (0..<(LinkLimits.maxApps + 50)).map { app(UInt32($0), "b\($0)", "App \($0)") }
        dir.receive(many)
        #expect(dir.installed.count == LinkLimits.maxApps)
    }

    @Test func sectionsShowRunningFirstAndRecentWithoutDuplicates() {
        let ws = workspace(
            [makeWindow(1, bundle: "r", title: "a"), makeWindow(2, bundle: "r", title: "b"), makeWindow(3, bundle: "r", kind: .transient)],
            apps: [app(1, "r", "Notes")])
        var dir = AppsDirectory()
        _ = dir.willRequest(.recent); dir.receive([app(1, "r", "Notes"), app(2, "x", "Zed")])
        _ = dir.willRequest(.installed); dir.receive([app(2, "x", "Zed"), app(3, "c", "calc"), app(4, "b", "Books")])
        let listing = LauncherListing.build(directory: dir, workspace: ws, badges: ["r": 2], query: "")
        #expect(listing.sections.map(\.section) == [.running, .recent, .installed])
        #expect(listing.sections[0].entries.first?.windowCount == 2)  // the transient one does not count
        #expect(listing.sections[0].entries.first?.badge == 2)
        #expect(listing.sections[1].entries.map(\.id) == ["x"])
        #expect(listing.sections[2].entries.map(\.id) == ["b", "c", "x"])
        #expect(listing.sections[2].entries.first { $0.id == "x" }?.isRunning == false)
    }

    @Test func searchIgnoresCaseAndDiacriticsAndMergesLists() {
        var dir = AppsDirectory()
        _ = dir.willRequest(.installed); dir.receive([app(2, "com.x.cafe", "Café"), app(3, "c", "Calc")])
        let ws = workspace([], apps: [app(1, "r", "Cafeteria")])
        let listing = LauncherListing.build(directory: dir, workspace: ws, query: "  CAFE ")
        #expect(listing.sections.count == 1 && listing.sections[0].section == .results)
        #expect(listing.sections[0].entries.map(\.id) == ["r", "com.x.cafe"])
        #expect(LauncherListing.build(directory: dir, workspace: ws, query: "com.x").sections[0].entries.map(\.id) == ["com.x.cafe"])
        #expect(LauncherListing.build(directory: dir, workspace: ws, query: "nothing").isEmpty)
    }

    @Test func tappingAnAppPlansLaunchActivateOrShow() {
        let none = workspace([], apps: [app(1, "r", "R")])
        #expect(AppOpenPlan.make(bundleID: "q", workspace: none, bindings: SceneBindings(), style: .separateWindows, canOpenSeveralScenes: true).start == .launch)
        #expect(AppOpenPlan.make(bundleID: "r", workspace: none, bindings: SceneBindings(), style: .separateWindows, canOpenSeveralScenes: true).start == .activateAndWait)

        let ws = workspace([makeWindow(1, bundle: "r"), makeWindow(2, bundle: "r"), makeWindow(3, bundle: "r")], apps: [app(1, "r", "R")])
        var bindings = SceneBindings()
        bindings.open(window: 2, in: SceneID("s"), workspace: ws)
        let separate = AppOpenPlan.make(bundleID: "r", workspace: ws, bindings: bindings, style: .separateWindows, canOpenSeveralScenes: true)
        #expect(separate.windowsToOpen == [1, 3] && separate.windowsToFocus == [2])
        let tabs = AppOpenPlan.make(bundleID: "r", workspace: ws, bindings: bindings, style: .tabs, canOpenSeveralScenes: true)
        #expect(tabs.windowsToOpen.isEmpty && tabs.windowsToFocus == [2])  // the app already has its scene
        let fresh = AppOpenPlan.make(bundleID: "r", workspace: ws, bindings: SceneBindings(), style: .tabs, canOpenSeveralScenes: true)
        #expect(fresh.windowsToOpen == [1])
        let phone = AppOpenPlan.make(bundleID: "r", workspace: ws, bindings: SceneBindings(), style: .separateWindows, canOpenSeveralScenes: false)
        #expect(phone.windowsToOpen == [1])
    }

    @Test func newWindowsOpenOrBadgeAccordingToPolicy() {
        var ws = workspace([makeWindow(1, bundle: "a")], apps: [app(1, "a", "A")])
        var inbox = NewWindowInbox()
        inbox.update(workspace: ws, policy: .autoOpen, sceneApps: ["a"], expecting: [], bound: [1])
        #expect(inbox.toOpen.isEmpty && inbox.badges.isEmpty)  // the first snapshot is the baseline

        ws.apply(.windowCreated(makeWindow(2, bundle: "a", title: "new")))
        ws.apply(.windowCreated(makeWindow(3, bundle: "b", title: "other app")))
        inbox.update(workspace: ws, policy: .autoOpen, sceneApps: ["a"], expecting: [], bound: [1])
        #expect(inbox.toOpen == [2])
        #expect(inbox.badges == ["b": 1])
        let r24 = inbox.takeToOpen()
        #expect(r24 == [2] && inbox.toOpen.isEmpty)

        // Policy badge: nothing opens by itself.
        ws.apply(.windowCreated(makeWindow(4, bundle: "a")))
        inbox.update(workspace: ws, policy: .badge, sceneApps: ["a"], expecting: [], bound: [1, 2])
        #expect(inbox.toOpen.isEmpty && inbox.badges == ["a": 1, "b": 1])

        // A window that gets a scene or goes away stops counting; clearing works.
        ws.apply(.windowDestroyed(3))
        inbox.update(workspace: ws, policy: .badge, sceneApps: [], expecting: [], bound: [1, 2, 4])
        #expect(inbox.badges.isEmpty)
    }

    @Test func aLaunchedAppsFirstWindowOpensEvenWithoutAScene() {
        var ws = workspace([], apps: [])
        var inbox = NewWindowInbox()
        inbox.update(workspace: ws, policy: .badge, sceneApps: [], expecting: ["n"], bound: [])
        ws.apply(.appsChanged(change: .launched, app: app(5, "n", "N")))
        ws.apply(.windowCreated(makeWindow(10, bundle: "n")))
        ws.apply(.windowCreated(makeWindow(11, bundle: "n")))
        let fulfilled = inbox.update(workspace: ws, policy: .badge, sceneApps: [], expecting: ["n"], bound: [])
        #expect(fulfilled == ["n"])
        #expect(inbox.toOpen.count == 1)
        #expect(inbox.badges == ["n": 1])  // the second one only badges
    }

    @Test func rebaselineForgetsWhatWasNew() {
        var ws = workspace([makeWindow(1, bundle: "a")])
        var inbox = NewWindowInbox()
        inbox.update(workspace: ws, policy: .badge, sceneApps: [], expecting: [], bound: [])
        ws.apply(.windowCreated(makeWindow(2, bundle: "a")))
        inbox.update(workspace: ws, policy: .badge, sceneApps: [], expecting: [], bound: [])
        #expect(inbox.badges == ["a": 1])
        inbox.rebaseline(ws)
        #expect(inbox.badges.isEmpty)
    }

    @Test func switcherMarksCurrentAndWindowsShownElsewhere() {
        let ws = workspace([makeWindow(1, bundle: "a", title: "One"), makeWindow(2, bundle: "a", title: "Two"), makeWindow(3, bundle: "b", title: "Three")],
                           apps: [app(1, "a", "Alpha")])
        var bindings = SceneBindings()
        bindings.open(window: 1, in: SceneID("me"), workspace: ws)
        bindings.open(window: 2, in: SceneID("other"), workspace: ws)
        let items = WindowSwitcher.items(workspace: ws, current: 1, bindings: bindings, thisScene: SceneID("me"))
        #expect(items.map(\.id) == [1, 2, 3])
        #expect(items[0].isCurrent && !items[0].isShownElsewhere)
        #expect(items[1].isShownElsewhere && !items[2].isShownElsewhere)
        #expect(items[0].appName == "Alpha" && items[2].appName == "b")
        #expect(WindowSwitcher.items(workspace: ws, current: 1, bindings: bindings, thisScene: SceneID("me"), onlyApp: "b").map(\.id) == [3])
    }

    @Test func sectionTitlesAreEnglish() {
        #expect(LauncherSection.running.title == "Running")
    }
}

@Suite("Remote menu mapping")
struct RemoteMenuTests {
    private let tree: [LinkMenuItem] = [
        LinkMenuItem(title: "File", children: [
            LinkMenuItem(title: "New", keyEquivalent: "n", modifiers: [.command]),
            LinkMenuItem(title: "", isSeparator: true),
            LinkMenuItem(title: "Close", keyEquivalent: "w", modifiers: [.command]),
            LinkMenuItem(title: "Hide", keyEquivalent: "h", modifiers: [.command]),
        ]),
        LinkMenuItem(title: "Edit", children: [
            LinkMenuItem(title: "Undo", keyEquivalent: "z", modifiers: [.command]),
            LinkMenuItem(title: "Redo", enabled: false, keyEquivalent: "z", modifiers: [.command, .shift]),
            LinkMenuItem(title: "Undo again", keyEquivalent: "Z", modifiers: [.command]),
            LinkMenuItem(title: "Plain", keyEquivalent: "p"),
        ]),
    ]

    @Test func pathsAreIndicesIncludingSeparators() throws {
        let entries = RemoteMenuMapper.entries(from: tree)
        #expect(entries[0].path == [0] && entries[0].isSubmenu)
        #expect(entries[0].children?[2].path == [0, 2] && entries[0].children?[2].title == "Close")
        #expect(entries[0].children?[1].isSeparator == true)
        let item = try #require(RemoteMenuMapper.item(at: [0, 2], in: tree))
        #expect(item.title == "Close")
        #expect(RemoteMenuMapper.item(at: [0, 9], in: tree) == nil)
        #expect(RemoteMenuMapper.item(at: [], in: tree) == nil)
        #expect(RemoteMenuMapper.item(at: [5], in: tree) == nil)
    }

    @Test func keyCommandsSkipReservedDisabledDuplicateAndUnmodified() {
        let entries = RemoteMenuMapper.entries(from: tree)
        let commands = RemoteMenuMapper.keyCommands(from: entries, closePolicy: .sendToMac)
        #expect(commands.map(\.title) == ["New", "Close", "Undo"])  // Hide is reserved, Redo disabled, "Undo again" a duplicate, Plain has no modifier
        #expect(commands.first { $0.title == "Close" }?.path == [0, 2])
    }

    @Test func commandWBelongsToScreonWhenItClosesTheIPadWindow() {
        let commands = RemoteMenuMapper.keyCommands(from: RemoteMenuMapper.entries(from: tree), closePolicy: .closeIPadWindow)
        #expect(!commands.contains { $0.title == "Close" })
        #expect(commands.contains { $0.title == "New" })
    }

    @Test func keyEquivalentsMapToUIKitInputs() {
        #expect(MenuShortcut(keyEquivalent: "N", modifiers: [.command])?.input == "n")
        #expect(MenuShortcut(keyEquivalent: "\u{F700}", modifiers: [.command])?.input == "UIKeyInputUpArrow")
        #expect(MenuShortcut(keyEquivalent: "\u{1B}", modifiers: [])?.input == "UIKeyInputEscape")
        #expect(MenuShortcut(keyEquivalent: "\u{7F}", modifiers: [.command])?.input == "\u{8}")
        #expect(MenuShortcut(keyEquivalent: "\r", modifiers: [.command])?.input == "\r")
        #expect(MenuShortcut(keyEquivalent: "", modifiers: [.command]) == nil)
        #expect(MenuShortcut(keyEquivalent: "ab", modifiers: [.command]) == nil)
        #expect(MenuShortcut(keyEquivalent: "\u{F704}", modifiers: [.command]) == nil)  // F1
        #expect(MenuShortcut(keyEquivalent: "\u{01}", modifiers: [.command]) == nil)
        // Caps lock and fn are not part of a shortcut.
        #expect(MenuShortcut(keyEquivalent: "a", modifiers: [.command, .capsLock, .function])?.modifiers == [.command])
    }

    @Test func deepOrHugeTreesAreCut() {
        var item = LinkMenuItem(title: "leaf")
        for i in 0..<20 { item = LinkMenuItem(title: "level \(i)", children: [item]) }
        var depth = 0
        var current = RemoteMenuMapper.entries(from: [item])
        while let first = current.first?.children { depth += 1; current = first }
        #expect(depth < LinkLimits.maxMenuDepth)
        let wide = (0..<5000).map { LinkMenuItem(title: "i\($0)") }
        #expect(RemoteMenuMapper.entries(from: wide).count <= 2000)
    }

    @Test func pathNumbersFromOutsideAreValidated() {
        #expect(RemoteMenuMapper.decodePath([0, 3]) == [0, 3])
        #expect(RemoteMenuMapper.decodePath([]) == nil)
        #expect(RemoteMenuMapper.decodePath([-1]) == nil)
        #expect(RemoteMenuMapper.decodePath([70000]) == nil)
        #expect(RemoteMenuMapper.decodePath(Array(repeating: 1, count: 40)) == nil)
    }

    @Test func cacheFetchesOnFocusRefreshesWhenOldAndReportsChanges() {
        var cache = MenuTreeCache(maxAge: 10, requestGap: 1)
        let r25 = cache.shouldRequest(bundleID: "a", at: 0)
        #expect(r25)
        let r26 = cache.shouldRequest(bundleID: "a", at: 0.5)
        #expect(!r26)  // reply on its way
        let r27 = cache.receive(bundleID: "a", items: tree, at: 0.6)
        #expect(r27)
        let r28 = cache.shouldRequest(bundleID: "a", at: 5)
        #expect(!r28)  // fresh
        let r29 = cache.shouldRequest(bundleID: "a", at: 11)
        #expect(r29)  // old
        let r30 = cache.receive(bundleID: "a", items: tree, at: 11.2)
        #expect(!r30)  // same tree: no rebuild
        #expect(cache.entry(for: "a")?.receivedAt == 11.2)
        let r31 = cache.shouldRequest(bundleID: "a", at: 13, force: true)
        #expect(r31)
        let r32 = cache.receive(bundleID: "a", items: [LinkMenuItem(title: "X")], at: 13.1)
        #expect(r32)
        cache.reset()
        #expect(cache.entry(for: "a") == nil)
    }

    @Test func cacheIsBoundedInApps() {
        var cache = MenuTreeCache()
        for i in 0..<(MenuTreeCache.maxApps + 10) { cache.receive(bundleID: "a\(i)", items: [], at: 0) }
        #expect(cache.entry(for: "a\(MenuTreeCache.maxApps + 5)") == nil)
        #expect(cache.entry(for: "a0") != nil)
    }

    @Test func windowActionsFollowCapabilities() {
        let none = WindowActionAvailability(window: nil)
        #expect(none.canClose && none.canMinimise && none.canZoom && !none.canExitFullScreen)
        var state = WindowState(info: makeWindow(1, flags: [.fullScreen]), capabilities: [.closable])
        let limited = WindowActionAvailability(window: state)
        #expect(limited.canClose && !limited.canMinimise && !limited.canZoom && !limited.canResize && limited.canExitFullScreen)
        state.capabilities = [.minimisable, .zoomable, .resizable]
        #expect(!WindowActionAvailability(window: state).canClose)
    }
}
