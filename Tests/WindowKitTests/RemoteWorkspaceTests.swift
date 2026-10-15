import Foundation
import LinkProtocol
import Testing
@testable import WindowKit

@Suite("RemoteWorkspace")
struct RemoteWorkspaceTests {
    @Test func snapshotReplacesEverything() {
        var ws = workspace([makeWindow(1), makeWindow(2)], apps: [makeApp(1)])
        let change = ws.apply(.snapshot(makeSnapshot(version: 5, apps: [makeApp(2, bundle: "b", name: "B")], windows: [makeWindow(3)], active: 3)))
        #expect(change.didChange)
        #expect(ws.zOrder == [3])
        #expect(ws.windows.keys.sorted() == [3])
        #expect(ws.apps.keys.sorted() == [2])
        #expect(ws.activeWindow == 3)
        #expect(ws.stateVersion == 5)
    }

    @Test func deltaBeforeSnapshotAsksForResync() {
        var ws = RemoteWorkspace()
        #expect(ws.apply(.windowCreated(makeWindow(1))).resync == .noSnapshot)
        #expect(ws.apply(.windowUpdated(LinkWindowUpdate(id: 1, stateVersion: 2, title: "x"))).resync == .noSnapshot)
        #expect(ws.apply(.windowOrder(ids: [1], active: nil)).resync == .noSnapshot)
        #expect(ws.windows.isEmpty)
    }

    @Test func createdGoesToFrontAndUpdatedChangesFields() {
        var ws = workspace([makeWindow(1)])
        ws.apply(.windowCreated(makeWindow(2)))
        #expect(ws.zOrder == [2, 1])
        let frame = LinkRect(x: 0, y: 0, width: 50, height: 60)
        let change = ws.apply(.windowUpdated(LinkWindowUpdate(id: 2, stateVersion: 3, frame: frame, title: "New", flags: [.focused])))
        #expect(change.didChange && change.resync == nil)
        #expect(ws.window(2)?.title == "New")
        #expect(ws.window(2)?.info.frame == frame)
        #expect(ws.window(2)?.info.flags == [.focused])
        #expect(ws.stateVersion == 3)
        // Fields that are absent stay as they were.
        #expect(ws.window(2)?.info.scale == 2)
    }

    @Test func staleUpdateIsIgnored() {
        var ws = workspace([makeWindow(1)], version: 10)
        let stale = ws.apply(.windowUpdated(LinkWindowUpdate(id: 1, stateVersion: 10, title: "old")))
        #expect(stale == .unchanged)
        #expect(ws.window(1)?.title == "Window")
        ws.apply(.windowUpdated(LinkWindowUpdate(id: 1, stateVersion: 12, title: "new")))
        ws.apply(.windowUpdated(LinkWindowUpdate(id: 1, stateVersion: 11, title: "reordered")))
        #expect(ws.window(1)?.title == "new")
    }

    @Test func updateOfUnknownWindowAsksForResync() {
        var ws = workspace([makeWindow(1)])
        let change = ws.apply(.windowUpdated(LinkWindowUpdate(id: 9, stateVersion: 9, title: "x")))
        #expect(change == WorkspaceChange(didChange: false, resync: .unknownWindow(9)))
        #expect(ws.apply(.windowCapabilities(window: 9, capabilities: .closable)).resync == .unknownWindow(9))
    }

    @Test func invalidUpdateFieldsAreIgnored() {
        var ws = workspace([makeWindow(1)])
        let bad = LinkWindowUpdate(
            id: 1, stateVersion: 2, frame: LinkRect(x: .nan, y: 0, width: 10, height: 10), scale: 0,
            minSize: LinkSize(width: -1, height: 0)
        )
        let change = ws.apply(.windowUpdated(bad))
        #expect(!change.didChange)
        #expect(ws.window(1)?.info == makeWindow(1))
    }

    @Test func destroyedIsIdempotentAndClearsActive() {
        var ws = workspace([makeWindow(1), makeWindow(2)])
        ws.apply(.windowOrder(ids: [1, 2], active: 1))
        #expect(ws.apply(.windowDestroyed(1)).didChange)
        #expect(ws.activeWindow == nil)
        #expect(ws.zOrder == [2])
        #expect(ws.apply(.windowDestroyed(1)) == .unchanged)
        #expect(ws.apply(.windowDestroyed(77)) == .unchanged)
    }

    @Test func destroyingParentRemovesTransientsAndDetachesManaged() {
        var ws = workspace([
            makeWindow(1), makeWindow(2, parent: 1, kind: .transient), makeWindow(3, parent: 2, kind: .transient),
            makeWindow(4, parent: 1, kind: .managed), makeWindow(5),
        ])
        ws.apply(.windowDestroyed(1))
        #expect(ws.windows.keys.sorted() == [4, 5])
        #expect(ws.window(4)?.parentID == nil)
        #expect(ws.zOrder == [4, 5])
    }

    @Test func orderKeepsUnlistedWindowsBehindAndReportsUnknownIds() {
        var ws = workspace([makeWindow(1), makeWindow(2), makeWindow(3), makeWindow(4)])
        let change = ws.apply(.windowOrder(ids: [3, 99, 3, 1], active: 3))
        #expect(ws.zOrder == [3, 1, 2, 4])
        #expect(ws.activeWindow == 3)
        #expect(change.resync == .unknownWindow(99))
        let unknownActive = ws.apply(.windowOrder(ids: [2], active: 88))
        #expect(ws.activeWindow == nil)
        #expect(unknownActive.resync == .unknownWindow(88))
    }

    @Test func orderIsCappedAtTheProtocolLimit() {
        var ws = workspace([makeWindow(1), makeWindow(2)])
        let flood = (0..<(LinkLimits.maxWindowsInOrder * 3)).map { WindowID(UInt32($0 % 2 + 1)) }
        ws.apply(.windowOrder(ids: flood, active: nil))
        #expect(ws.zOrder == [1, 2])
    }

    // MARK: Hostile input

    @Test func createdWithUnknownParentIsRejected() {
        var ws = workspace([makeWindow(1)])
        let change = ws.apply(.windowCreated(makeWindow(2, parent: 50, kind: .transient)))
        #expect(change == WorkspaceChange(didChange: false, resync: .unknownParent(2)))
        #expect(ws.window(2) == nil)
        #expect(ws.apply(.windowCreated(makeWindow(3, parent: 3, kind: .transient))).resync == .unknownParent(3))
    }

    @Test func createdCannotCloseACycle() {
        var ws = workspace([makeWindow(1), makeWindow(2, parent: 1, kind: .transient)])
        // Window 1 is announced again as a child of its own child.
        let change = ws.apply(.windowCreated(makeWindow(1, parent: 2, kind: .transient)))
        #expect(change.resync == .unknownParent(1))
        #expect(ws.window(1)?.parentID == nil)
    }

    @Test func duplicateCreatedReplacesInPlace() {
        var ws = workspace([makeWindow(1), makeWindow(2)])
        ws.apply(.windowCreated(makeWindow(2, title: "again")))
        #expect(ws.zOrder == [1, 2])
        #expect(ws.window(2)?.title == "again")
        #expect(ws.apply(.windowCreated(makeWindow(2, title: "again"))) == .unchanged)
    }

    @Test func invalidCreatedIsRejected() {
        var ws = workspace([])
        let bad = makeWindow(1, frame: LinkRect(x: 0, y: 0, width: -5, height: 10))
        #expect(ws.apply(.windowCreated(bad)).resync == .invalidWindow(1))
        #expect(ws.apply(.windowCreated(makeWindow(2, scale: 0))).resync == .invalidWindow(2))
        #expect(ws.apply(.windowCreated(makeWindow(3, scale: .infinity))).resync == .invalidWindow(3))
        #expect(ws.windows.isEmpty)
    }

    @Test func snapshotSanitisesDuplicatesCyclesAndUnknownParents() {
        let ws = workspace([
            makeWindow(1, title: "first"), makeWindow(1, title: "duplicate"),
            makeWindow(2, parent: 3, kind: .transient), makeWindow(3, parent: 2, kind: .transient),
            makeWindow(4, parent: 4, kind: .transient), makeWindow(5, parent: 99, kind: .transient),
            makeWindow(6, parent: 1, kind: .transient),
        ])
        #expect(ws.window(1)?.title == "first")
        #expect(ws.zOrder == [1, 2, 3, 4, 5, 6])
        // Every parent chain ends: no cycles remain and unknown parents are gone.
        for id in ws.zOrder {
            #expect(ws.rootWindow(of: id) != nil)
        }
        #expect(ws.window(4)?.parentID == nil)
        #expect(ws.window(5)?.parentID == nil)
        #expect(ws.window(6)?.parentID == 1)
    }

    @Test func snapshotCountsAreCapped() {
        let windows = (1...(LinkLimits.maxWindowsPerSnapshot + 50)).map { makeWindow(UInt32($0)) }
        let apps = (1...(LinkLimits.maxApps + 10)).map { makeApp(UInt32($0), bundle: "b\($0)") }
        let ws = workspace(windows, apps: apps)
        #expect(ws.windows.count == LinkLimits.maxWindowsPerSnapshot)
        #expect(ws.apps.count == LinkLimits.maxApps)
    }

    @Test func createdOverTheCapAsksForResync() {
        let windows = (1...LinkLimits.maxWindowsPerSnapshot).map { makeWindow(UInt32($0)) }
        var ws = workspace(windows)
        let change = ws.apply(.windowCreated(makeWindow(5000)))
        #expect(change.resync == .capacityExceeded)
        #expect(ws.windows.count == LinkLimits.maxWindowsPerSnapshot)
    }

    @Test func snapshotActiveWindowMustExist() {
        let ws = workspace([makeWindow(1)])
        var other = ws
        other.apply(.snapshot(makeSnapshot(version: 2, windows: [makeWindow(1)], active: 42)))
        #expect(other.activeWindow == nil)
    }

    // MARK: Apps

    @Test func appChangesLaunchActivateTerminate() {
        var ws = workspace([], apps: [makeApp(1, bundle: "a", name: "A", active: true)])
        ws.apply(.appsChanged(change: .launched, app: makeApp(2, bundle: "b", name: "B")))
        #expect(ws.apps.count == 2)
        ws.apply(.appsChanged(change: .activated, app: makeApp(2, bundle: "b", name: "B")))
        #expect(ws.apps[2]?.isActive == true && ws.apps[1]?.isActive == false)
        ws.apply(.appsChanged(change: .terminated, app: makeApp(1, bundle: "a", name: "A")))
        #expect(ws.apps.keys.sorted() == [2])
    }

    @Test func sortedAppsAreCaseInsensitive() {
        let ws = workspace([], apps: [makeApp(1, bundle: "z", name: "zeta"), makeApp(2, bundle: "a", name: "Alpha"), makeApp(3, bundle: "m", name: "Mail")])
        #expect(ws.sortedApps.map(\.name) == ["Alpha", "Mail", "zeta"])
    }

    // MARK: Queries

    @Test func managedWindowsPerAppAreFrontToBack() {
        var ws = workspace([makeWindow(1, bundle: "a"), makeWindow(2, bundle: "b"), makeWindow(3, bundle: "a"), makeWindow(4, parent: 1, kind: .transient)])
        #expect(ws.managedWindows(bundleID: "a").map(\.id) == [1, 3])
        ws.apply(.windowOrder(ids: [3, 2, 1], active: nil))
        #expect(ws.managedWindows(bundleID: "a").map(\.id) == [3, 1])
    }

    @Test func transientSurfacesGroupUnderTheirParentByZ() {
        let ws = workspace([
            makeWindow(10, parent: 1, kind: .transient), makeWindow(1), makeWindow(11, parent: 10, kind: .transient),
            makeWindow(12, parent: 2, kind: .transient), makeWindow(2), makeWindow(13, parent: 1, kind: .transient),
        ])
        #expect(ws.children(of: 1).map(\.id) == [10, 13])
        #expect(ws.transientSurfaces(of: 1).map(\.id) == [10, 11, 13])
        #expect(ws.transientSurfaces(of: 2).map(\.id) == [12])
        #expect(ws.rootWindow(of: 11)?.id == 1)
        #expect(ws.rootWindow(of: 1)?.id == 1)
        #expect(ws.rootWindow(of: 404) == nil)
    }

    @Test func launcherListIsSortedByAppThenZ() {
        var ws = workspace(
            [makeWindow(1, bundle: "m"), makeWindow(2, bundle: "a"), makeWindow(3, bundle: "m"), makeWindow(4, parent: 1, kind: .transient)],
            apps: [makeApp(1, bundle: "m", name: "Mail"), makeApp(2, bundle: "a", name: "Atlas")]
        )
        #expect(ws.windowsForLauncher.map(\.id) == [2, 1, 3])
        ws.apply(.windowOrder(ids: [3, 1], active: nil))
        #expect(ws.windowsForLauncher.map(\.id) == [2, 3, 1])
    }

    @Test func windowsOfUnknownAppsSortByBundleID() {
        let ws = workspace([makeWindow(1, bundle: "com.b"), makeWindow(2, bundle: "com.a")])
        #expect(ws.windowsForLauncher.map(\.id) == [2, 1])
    }

    @Test func resetForgetsEverything() {
        var ws = workspace([makeWindow(1)])
        ws.reset()
        #expect(ws == RemoteWorkspace())
    }
}

// MARK: - Property test

/// A plain model of the Mac. Operations change it and produce the matching delta.
private struct Truth {
    var version: UInt64 = 1
    var windows: [LinkWindowInfo] = [] // front to back
    var apps: [AppRef: LinkAppInfo] = [:]
    var active: WindowID?
    var nextID: UInt32 = 1

    var snapshot: LinkSnapshot {
        LinkSnapshot(stateVersion: version, apps: apps.values.sorted { $0.ref < $1.ref }, windows: windows, activeWindow: active)
    }

    mutating func step(_ rng: inout SeededGenerator) -> [LinkMessage] {
        switch Int.random(in: 0..<7, using: &rng) {
        case 0, 1: return create(&rng)
        case 2, 3: return update(&rng)
        case 4: return destroy(&rng)
        case 5: return reorder(&rng)
        default: return changeApp(&rng)
        }
    }

    private mutating func create(_ rng: inout SeededGenerator) -> [LinkMessage] {
        let id = nextID
        nextID += 1
        let parent = windows.randomElement(using: &rng).flatMap { $0.kind == .managed && Bool.random(using: &rng) ? $0.id : nil }
        let info = makeWindow(
            id, bundle: "app.\(Int.random(in: 0..<3, using: &rng))", title: "T\(Int.random(in: 0..<5, using: &rng))",
            parent: parent?.rawValue, kind: parent == nil ? .managed : .transient
        )
        windows.insert(info, at: 0)
        return [.windowCreated(info)]
    }

    private mutating func update(_ rng: inout SeededGenerator) -> [LinkMessage] {
        guard let index = windows.indices.randomElement(using: &rng) else { return [] }
        version += 1
        var update = LinkWindowUpdate(id: windows[index].id, stateVersion: version)
        if Bool.random(using: &rng) {
            update.title = "U\(version)"
            windows[index].title = "U\(version)"
        }
        if Bool.random(using: &rng) {
            let frame = LinkRect(x: Double(version), y: 1, width: 100 + Double(version), height: 80)
            update.frame = frame
            windows[index].frame = frame
        }
        if Bool.random(using: &rng) {
            update.flags = [.onScreen]
            windows[index].flags = [.onScreen]
        }
        return [.windowUpdated(update)]
    }

    private mutating func destroy(_ rng: inout SeededGenerator) -> [LinkMessage] {
        guard let victim = windows.randomElement(using: &rng) else { return [] }
        // Children are destroyed first, as the helper reports them.
        var doomed: [WindowID] = [victim.id]
        var index = 0
        while index < doomed.count {
            doomed += windows.filter { $0.parentID == doomed[index] }.map(\.id)
            index += 1
        }
        windows.removeAll { doomed.contains($0.id) }
        if let active, doomed.contains(active) { self.active = nil }
        return doomed.reversed().map { .windowDestroyed($0) }
    }

    private mutating func reorder(_ rng: inout SeededGenerator) -> [LinkMessage] {
        windows.shuffle(using: &rng)
        active = windows.randomElement(using: &rng)?.id
        return [.windowOrder(ids: windows.map(\.id), active: active)]
    }

    private mutating func changeApp(_ rng: inout SeededGenerator) -> [LinkMessage] {
        let ref = UInt32.random(in: 1...4, using: &rng)
        let app = makeApp(ref, bundle: "app.\(ref)", name: "App \(ref)")
        if apps[AppRef(ref)] != nil && Bool.random(using: &rng) {
            apps[AppRef(ref)] = nil
            return [.appsChanged(change: .terminated, app: app)]
        }
        apps[AppRef(ref)] = app
        return [.appsChanged(change: .launched, app: app)]
    }
}

@Suite("RemoteWorkspace convergence")
struct RemoteWorkspaceConvergenceTests {
    @Test(arguments: Array(UInt64(1)...40))
    func deltasConvergeToTheSnapshot(seed: UInt64) {
        var rng = SeededGenerator(seed: seed)
        var truth = Truth()
        for _ in 0..<Int.random(in: 0..<6, using: &rng) { _ = truth.step(&rng) }
        var incremental = RemoteWorkspace()
        incremental.apply(.snapshot(truth.snapshot))

        for stepNumber in 0..<120 {
            for message in truth.step(&rng) {
                let change = incremental.apply(message)
                #expect(change.resync == nil, "seed \(seed) step \(stepNumber): unexpected resync \(String(describing: change.resync))")
            }
            if stepNumber % 20 == 19 {
                var fresh = RemoteWorkspace()
                fresh.apply(.snapshot(truth.snapshot))
                #expect(incremental.hasSameContent(as: fresh), "seed \(seed) step \(stepNumber)")
            }
        }
    }

    @Test(arguments: Array(UInt64(100)...120))
    func replayingDeltasIsHarmless(seed: UInt64) {
        // Every window.updated is applied twice: the second one is stale and changes nothing.
        var rng = SeededGenerator(seed: seed)
        var truth = Truth()
        var once = RemoteWorkspace(), twice = RemoteWorkspace()
        once.apply(.snapshot(truth.snapshot))
        twice.apply(.snapshot(truth.snapshot))
        for _ in 0..<80 {
            for message in truth.step(&rng) {
                once.apply(message)
                twice.apply(message)
                if case .windowUpdated = message { #expect(twice.apply(message) == .unchanged) }
            }
        }
        #expect(once.hasSameContent(as: twice))
    }

    @Test(arguments: Array(UInt64(200)...230))
    func randomGarbageNeverCrashesAndKeepsInvariants(seed: UInt64) {
        var rng = SeededGenerator(seed: seed)
        var ws = workspace([makeWindow(1), makeWindow(2, parent: 1, kind: .transient)])
        func randomID() -> WindowID { WindowID(UInt32.random(in: 0..<12, using: &rng)) }
        for _ in 0..<400 {
            switch Int.random(in: 0..<6, using: &rng) {
            case 0:
                let parent = Bool.random(using: &rng) ? randomID() : nil
                ws.apply(.windowCreated(makeWindow(randomID().rawValue, parent: parent?.rawValue, kind: parent == nil ? .managed : .transient)))
            case 1: ws.apply(.windowUpdated(LinkWindowUpdate(id: randomID(), stateVersion: UInt64.random(in: 0..<50, using: &rng), title: "g")))
            case 2: ws.apply(.windowDestroyed(randomID()))
            case 3: ws.apply(.windowOrder(ids: (0..<5).map { _ in randomID() }, active: randomID()))
            case 4: ws.apply(.windowCapabilities(window: randomID(), capabilities: .closable))
            default:
                ws.apply(.snapshot(makeSnapshot(version: UInt64.random(in: 0..<50, using: &rng), windows: (0..<4).map { _ in
                    let parent = randomID()
                    return makeWindow(randomID().rawValue, parent: parent.rawValue, kind: .transient)
                })))
            }
            // Invariants: z-order and the window table agree, active exists, parents exist and chains end.
            #expect(Set(ws.zOrder) == Set(ws.windows.keys) && ws.zOrder.count == ws.windows.count)
            if let active = ws.activeWindow { #expect(ws.windows[active] != nil) }
            for id in ws.zOrder {
                if let parent = ws.windows[id]?.parentID { #expect(ws.windows[parent] != nil && parent != id) }
                #expect(ws.rootWindow(of: id) != nil)
            }
        }
    }
}
