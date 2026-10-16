#if os(macOS)
import Foundation
import LinkProtocol
import Testing
@testable import HelperCore

@Suite(.timeLimit(.minutes(2))) struct WindowTrackerTests {
    func makeTracker(_ system: FakeWindowSystem) async -> (WindowTracker, EventRecorder) {
        let tracker = WindowTracker(system: system)
        let recorder = EventRecorder()
        await tracker.observe { recorder.append($0) }
        return (tracker, recorder)
    }

    /// One app with one window, frontmost.
    func oneWindow() -> FakeWindowSystem {
        let system = FakeWindowSystem()
        system.pids = [100]
        system.frontmost = 100
        system.cg = [cgRecord(10, 100)]
        system.setAX(100, [axWindow(100, 1, cg: 10, focused: true)])
        return system
    }

    // MARK: Identity

    /// A window moved to another display (the stage) can come back from Accessibility as a different element. Its
    /// window-server number is the same, so it is the same window: no destroyed/created pair (the iPad would close it), and
    /// commands use the new element.
    @Test func aWindowKeepsItsIdentityWhenItsAXElementChanges() async throws {
        let system = oneWindow()
        let (tracker, recorder) = await makeTracker(system)
        await tracker.reconcile()
        let id = try #require(await tracker.snapshot().windows.first?.id)
        _ = recorder.take()

        system.cg = [cgRecord(10, 100, bounds: rect(3000, 0, 800, 600))]
        system.setAX(100, [axWindow(100, 99, cg: 10, frame: rect(3000, 0, 800, 600), focused: true)])
        await tracker.reconcile()

        let events = recorder.take()
        #expect(!events.contains { if case .destroyed = $0 { true } else { false } }, "\(events)")
        #expect(!events.contains { if case .created = $0 { true } else { false } }, "\(events)")
        #expect(await tracker.snapshot().windows.map(\.id) == [id])
        #expect(await tracker.stageKey(of: id) == StageWindowKey(pid: 100, windowNumber: 10))
    }

    /// A tooltip or hover card that Accessibility reports as a window must not become a managed window: the iPhone would
    /// switch to it and show "closed" a moment later.
    @Test func tooltipSizedAXWindowsAreNotManaged() async {
        let system = oneWindow()
        system.cg = [cgRecord(11, 100, bounds: rect(10, 40, 66, 20)), cgRecord(10, 100)]
        system.setAX(100, [axWindow(100, 1, cg: 10, focused: true), axWindow(100, 2, cg: 11, frame: rect(10, 40, 66, 20))])
        let (tracker, _) = await makeTracker(system)
        await tracker.reconcile()
        let managed = await tracker.snapshot().windows.filter { $0.kind == .managed }
        #expect(managed.count == 1)
        #expect(managed.first?.frame == rect(100, 100, 800, 600))
    }

    @Test func aMinimisedWindowStaysManagedWhateverItsSize() async {
        let system = oneWindow()
        system.setAX(100, [axWindow(100, 1, cg: 10, frame: rect(0, 0, 80, 40), minimised: true)])
        let (tracker, _) = await makeTracker(system)
        await tracker.reconcile()
        #expect(await tracker.snapshot().windows.filter { $0.kind == .managed }.count == 1)
    }

    /// Without a window-server number the AX element is the identity: a new element is a new window.
    @Test func withoutANumberTheAXElementIsTheIdentity() async throws {
        let system = FakeWindowSystem()
        system.pids = [100]; system.frontmost = 100
        system.cg = []
        system.setAX(100, [axWindow(100, 1, cg: nil, focused: true)])
        let (tracker, recorder) = await makeTracker(system)
        await tracker.reconcile()
        _ = recorder.take()
        system.setAX(100, [axWindow(100, 2, cg: nil, focused: true)])
        await tracker.reconcile()
        let events = recorder.take()
        #expect(events.contains { if case .destroyed = $0 { true } else { false } })
        #expect(events.contains { if case .created = $0 { true } else { false } })
    }

    // MARK: Lifecycle of a window

    @Test func createMoveResizeDestroy() async {
        let system = oneWindow()
        let (tracker, recorder) = await makeTracker(system)
        await tracker.reconcile()

        var events = recorder.take()
        guard case .created(let info, let v1) = events.first else { Issue.record("expected created, got \(events)"); return }
        #expect(info.pid == 100 && info.bundleID == "com.example.app100")
        #expect(info.kind == .managed && info.parentID == nil)
        #expect(info.frame == rect(100, 100, 800, 600) && info.title == "Window" && info.scale == 2)
        #expect(info.flags.contains(.onScreen) && info.flags.contains(.focused))
        guard case .order(let ids, let active, let v2) = events.last else { Issue.record("expected order"); return }
        #expect(ids == [info.id] && active == info.id && v2 == v1 + 1)

        // Move.
        system.setAX(100, [axWindow(100, 1, cg: 10, frame: rect(150, 120, 800, 600), focused: true)])
        await tracker.handle(.ax(pid: 100, .windowMoved))
        events = recorder.take()
        #expect(events.count == 1)
        guard case .updated(let move) = events[0] else { Issue.record("expected updated"); return }
        #expect(move.frame == rect(150, 120, 800, 600) && move.title == nil && move.flags == nil)

        // Resize and retitle at once.
        system.setAX(100, [axWindow(100, 1, cg: 10, frame: rect(150, 120, 900, 700), title: "Renamed", focused: true)])
        await tracker.handle(.ax(pid: 100, .windowResized))
        guard case .updated(let resize) = recorder.take()[0] else { Issue.record("expected updated"); return }
        #expect(resize.frame == rect(150, 120, 900, 700) && resize.title == "Renamed")

        // No change, no event.
        await tracker.handle(.ax(pid: 100, .titleChanged))
        #expect(recorder.take().isEmpty)

        // Destroy.
        system.setAX(100, [])
        system.cg = []
        await tracker.handle(.ax(pid: 100, .windowDestroyed))
        events = recorder.take()
        #expect(events.count == 2)
        guard case .destroyed(let gone, _) = events[0] else { Issue.record("expected destroyed"); return }
        #expect(gone == info.id)
        guard case .order(let emptyIDs, let noActive, _) = events[1] else { Issue.record("expected order"); return }
        #expect(emptyIDs.isEmpty && noActive == nil)
    }

    @Test func windowIDsAreNeverReused() async {
        let system = oneWindow()
        let (tracker, recorder) = await makeTracker(system)
        await tracker.reconcile()
        let first = await tracker.snapshot().windows[0].id
        system.setAX(100, []); system.cg = []
        await tracker.reconcile()
        system.setAX(100, [axWindow(100, 2, cg: 11)]); system.cg = [cgRecord(11, 100)]
        await tracker.reconcile()
        let second = await tracker.snapshot().windows[0].id
        #expect(second != first && second > first)
        _ = recorder
    }

    @Test func missedNotificationsAreCorrectedByReconciliation() async {
        let system = oneWindow()
        let (tracker, recorder) = await makeTracker(system)
        await tracker.reconcile()
        _ = recorder.take()

        // The window moves and a second one appears; no AX notification arrives.
        system.setAX(100, [axWindow(100, 1, cg: 10, frame: rect(0, 0, 500, 400), focused: true), axWindow(100, 2, cg: 11, frame: rect(300, 300, 400, 300))])
        system.cg = [cgRecord(11, 100, bounds: rect(300, 300, 400, 300)), cgRecord(10, 100, bounds: rect(0, 0, 500, 400))]
        await tracker.reconcile()
        let events = recorder.take()
        #expect(events.contains { if case .created = $0 { true } else { false } })
        #expect(events.contains { if case .updated(let u) = $0 { u.frame == rect(0, 0, 500, 400) } else { false } })
        let order = await tracker.snapshot()
        #expect(order.windows.count == 2)
        #expect(order.windows[0].frame == rect(300, 300, 400, 300), "CG order is front to back")
    }

    @Test func snapshotEqualsIncrementalState() async {
        let system = FakeWindowSystem()
        system.pids = [100, 200]
        system.frontmost = 100
        system.cg = [cgRecord(10, 100), cgRecord(20, 200, bounds: rect(400, 50, 300, 300)), cgRecord(30, 100, bounds: rect(120, 120, 100, 50), layer: 101)]
        system.setAX(100, [axWindow(100, 1, cg: 10, focused: true)])
        system.setAX(200, [axWindow(200, 1, cg: 20, frame: rect(400, 50, 300, 300), title: "Other")])
        let (tracker, recorder) = await makeTracker(system)
        var model = ClientModel()
        await tracker.reconcile()
        for e in recorder.take() { model.apply(e) }

        let script: [(String, @Sendable (FakeWindowSystem) -> Void)] = [
            ("move", { $0.setAX(200, [axWindow(200, 1, cg: 20, frame: rect(10, 10, 300, 300), title: "Other")]) }),
            ("menu closes", { $0.cg.removeAll { $0.layer == 101 } }),
            ("focus changes", { $0.frontmost = 200 }),
            ("minimise", { $0.setAX(100, [axWindow(100, 1, cg: 10, minimised: true)]) }),
            ("quit", { $0.removeApp(200) }),
            ("new window", { $0.setAX(100, [axWindow(100, 1, cg: 10), axWindow(100, 3, cg: 12, title: "Third")]); $0.cg.append(cgRecord(12, 100)) }),
        ]
        for (name, step) in script {
            step(system)
            await tracker.reconcile()
            for e in recorder.take() { model.apply(e) }
            let snapshot = await tracker.snapshot()
            #expect(model.ordered == snapshot.windows, "windows differ after \(name)")
            #expect(model.active == snapshot.activeWindow, "active differs after \(name)")
            #expect(model.version == snapshot.stateVersion, "version differs after \(name)")
        }
    }

    @Test func stateVersionIsStrictlyMonotonic() async {
        let system = oneWindow()
        let (tracker, recorder) = await makeTracker(system)
        await tracker.reconcile()
        for step in 0..<6 {
            system.setAX(100, [axWindow(100, 1, cg: 10, frame: rect(Double(step) * 10, 0, 800, 600), title: "t\(step)", focused: true)])
            await tracker.reconcile()
        }
        let versions = recorder.events.compactMap(\.stateVersion)
        #expect(versions == Array(versions.sorted()) && Set(versions).count == versions.count)
        #expect(await tracker.snapshot().stateVersion == versions.last)
    }

    // MARK: Active window

    @Test func activeWindowFollowsFocus() async {
        let system = FakeWindowSystem()
        system.pids = [100, 200]
        system.frontmost = 100
        system.cg = [cgRecord(10, 100), cgRecord(20, 200, bounds: rect(500, 500, 300, 300))]
        system.setAX(100, [axWindow(100, 1, cg: 10, focused: true)])
        system.setAX(200, [axWindow(200, 1, cg: 20, frame: rect(500, 500, 300, 300), focused: true)])
        let (tracker, recorder) = await makeTracker(system)
        await tracker.reconcile()
        let first = await tracker.snapshot()
        let w100 = first.windows.first { $0.pid == 100 }!, w200 = first.windows.first { $0.pid == 200 }!
        #expect(first.activeWindow == w100.id)
        #expect(w100.flags.contains(.focused) && !w200.flags.contains(.focused))
        _ = recorder.take()

        system.frontmost = 200
        await tracker.handle(.ax(pid: 200, .appActivated))
        let events = recorder.take()
        let flagUpdates = events.compactMap { event -> LinkWindowUpdate? in if case .updated(let u) = event { u } else { nil } }
        #expect(flagUpdates.count == 2)
        guard case .order(_, let active, _) = events.last else { Issue.record("expected order last"); return }
        #expect(active == w200.id)
    }

    // MARK: Identity fallbacks

    @Test func windowsMatchByFrameWhenTheWindowNumberCallIsUnavailable() async {
        let system = FakeWindowSystem()
        system.pids = [100]
        system.frontmost = 100
        system.cg = [cgRecord(10, 100, bounds: rect(100, 100, 800, 600)), cgRecord(11, 100, bounds: rect(200, 200, 400, 300))]
        system.setAX(100, [axWindow(100, 1, cg: nil, frame: rect(200, 200, 400, 300)), axWindow(100, 2, cg: nil, frame: rect(100, 100, 800, 600))])
        let (tracker, _) = await makeTracker(system)
        await tracker.reconcile()
        let snapshot = await tracker.snapshot()
        #expect(snapshot.windows.count == 2)
        #expect(snapshot.windows.allSatisfy { $0.flags.contains(.onScreen) })
        #expect(snapshot.windows[0].frame == rect(100, 100, 800, 600), "z-order comes from the matched CG record")
    }

    @Test func windowWithoutCGRecordIsStillTrackedButNotOnScreen() async {
        let system = FakeWindowSystem()
        system.pids = [100]
        system.cg = []
        system.setAX(100, [axWindow(100, 1, cg: 999, minimised: true)])
        let (tracker, _) = await makeTracker(system)
        await tracker.reconcile()
        let window = await tracker.snapshot().windows[0]
        #expect(window.flags.contains(.minimised) && !window.flags.contains(.onScreen))
    }

    // MARK: Transient surfaces

    @Test func menusAndSheetsBecomeTransientChildrenOfTheirWindow() async {
        let system = oneWindow()
        let (tracker, recorder) = await makeTracker(system)
        await tracker.reconcile()
        let parent = await tracker.snapshot().windows[0].id
        _ = recorder.take()

        // A menu (layer 101) overlapping the window, a sheet (layer 0, inside the window, no AX window).
        system.cg = [
            cgRecord(30, 100, bounds: rect(120, 100, 200, 300), layer: 101),
            cgRecord(31, 100, bounds: rect(200, 100, 400, 200), layer: 0),
            cgRecord(10, 100),
        ]
        await tracker.reconcile()
        let snapshot = await tracker.snapshot()
        #expect(snapshot.windows.count == 3)
        let transients = snapshot.windows.filter { $0.kind == .transient }
        #expect(transients.count == 2)
        #expect(transients.allSatisfy { $0.parentID == parent && $0.pid == 100 })
        #expect(transients.contains { $0.level == 101 })
        #expect(snapshot.windows.last?.kind == .managed, "the window is behind its popups")

        // The popup closes.
        system.cg = [cgRecord(10, 100)]
        await tracker.reconcile()
        #expect(await tracker.snapshot().windows.map(\.kind) == [.managed])
    }

    @Test func popupWithoutAParentAndSystemChromeAreIgnored() async {
        let system = oneWindow()
        system.cg = [
            cgRecord(10, 100),
            cgRecord(40, 100, bounds: rect(2000, 2000, 100, 100), layer: 101),   // does not touch any window
            cgRecord(41, 100, bounds: rect(120, 120, 100, 20), layer: 25),       // status item layer
            cgRecord(42, 100, bounds: rect(120, 120, 100, 20), layer: 101, alpha: 0), // invisible
            cgRecord(43, 100, bounds: rect(120, 120, 100, 20), layer: 101, onScreen: false),
        ]
        let (tracker, _) = await makeTracker(system)
        await tracker.reconcile()
        #expect(await tracker.snapshot().windows.count == 1)
    }

    @Test func popupBelongsToTheFrontmostIntersectingWindowOfItsOwner() async {
        let system = FakeWindowSystem()
        system.pids = [100]
        system.frontmost = 100
        system.cg = [
            cgRecord(50, 100, bounds: rect(250, 250, 50, 50), layer: 101),
            cgRecord(11, 100, bounds: rect(200, 200, 400, 400)),  // front
            cgRecord(10, 100, bounds: rect(100, 100, 400, 400)),  // behind
        ]
        system.setAX(100, [axWindow(100, 1, cg: 10, frame: rect(100, 100, 400, 400)), axWindow(100, 2, cg: 11, frame: rect(200, 200, 400, 400))])
        let (tracker, _) = await makeTracker(system)
        await tracker.reconcile()
        let windows = await tracker.snapshot().windows
        let front = windows.first { $0.frame == rect(200, 200, 400, 400) }!
        #expect(windows.first { $0.kind == .transient }?.parentID == front.id)
    }

    @Test func transientDestroyedWhenItsParentGoes() async {
        let system = oneWindow()
        system.cg = [cgRecord(30, 100, bounds: rect(120, 100, 200, 300), layer: 101), cgRecord(10, 100)]
        let (tracker, recorder) = await makeTracker(system)
        await tracker.reconcile()
        _ = recorder.take()
        system.setAX(100, []); system.cg = [cgRecord(30, 100, bounds: rect(120, 100, 200, 300), layer: 101)]
        await tracker.reconcile()
        let destroyed = recorder.take().filter { if case .destroyed = $0 { true } else { false } }
        #expect(destroyed.count == 2)
        #expect(await tracker.snapshot().windows.isEmpty)
    }

    // MARK: App lifecycle

    @Test func terminatedAppDestroysAllItsWindows() async {
        let system = FakeWindowSystem()
        system.pids = [100, 200]
        system.frontmost = 100
        system.cg = [cgRecord(10, 100), cgRecord(11, 100, bounds: rect(0, 0, 300, 300)), cgRecord(20, 200, bounds: rect(500, 500, 200, 200))]
        system.setAX(100, [axWindow(100, 1, cg: 10, focused: true), axWindow(100, 2, cg: 11, frame: rect(0, 0, 300, 300))])
        system.setAX(200, [axWindow(200, 1, cg: 20, frame: rect(500, 500, 200, 200))])
        let (tracker, recorder) = await makeTracker(system)
        await tracker.reconcile()
        #expect(system.observing == [100, 200])
        _ = recorder.take()

        system.removeApp(100)
        await tracker.handle(.appTerminated(pid: 100))
        let events = recorder.take()
        #expect(events.filter { if case .destroyed = $0 { true } else { false } }.count == 2)
        let snapshot = await tracker.snapshot()
        #expect(snapshot.windows.map(\.pid) == [200])
        #expect(system.observing == [200])
        #expect(await tracker.windowCounts() == [200: 1])
    }

    @Test func newAppAppearsOnLaunchEvent() async {
        let system = oneWindow()
        let (tracker, recorder) = await makeTracker(system)
        await tracker.reconcile()
        _ = recorder.take()
        system.pids.append(300)
        system.setAX(300, [axWindow(300, 1, cg: 90, frame: rect(10, 10, 100, 100))])
        system.cg.append(cgRecord(90, 300, bounds: rect(10, 10, 100, 100)))
        await tracker.handle(.appLaunched(pid: 300))
        #expect(await tracker.snapshot().windows.count == 2)
        #expect(system.observing.contains(300))
    }

    // MARK: Unresponsive apps

    @Test func unresponsiveAppKeepsLastKnownStateAndRecovers() async {
        let system = oneWindow()
        let (tracker, recorder) = await makeTracker(system)
        await tracker.reconcile()
        let before = await tracker.snapshot()
        _ = recorder.take()

        system.setAXError(100, .timeout)
        await tracker.handle(.ax(pid: 100, .windowMoved))
        await tracker.reconcile()
        #expect(recorder.take() == [.unresponsive(pid: 100, isUnresponsive: true)], "reported once, windows kept")
        #expect(await tracker.isUnresponsive(pid: 100))
        #expect(await tracker.snapshot().windows == before.windows)
        #expect(await tracker.snapshot().stateVersion == before.stateVersion)

        // CG data keeps flowing while AX is stuck.
        system.cg = [cgRecord(10, 100)]
        await tracker.reconcile()
        #expect(await tracker.snapshot().windows.count == 1)

        system.setAXError(100, nil)
        await tracker.reconcile()
        #expect(recorder.take() == [.unresponsive(pid: 100, isUnresponsive: false)])
        #expect(await tracker.isUnresponsive(pid: 100) == false)
    }

    @Test func accessibilityErrorsOtherThanTimeoutKeepStateQuietly() async {
        let system = oneWindow()
        let (tracker, recorder) = await makeTracker(system)
        await tracker.reconcile()
        _ = recorder.take()
        system.setAXError(100, .permissionDenied)
        await tracker.reconcile()
        #expect(recorder.take().isEmpty)
        #expect(await tracker.snapshot().windows.count == 1)
    }

    @Test func unresponsiveMessageIsLocalized() {
        #expect(WindowTracker.unresponsiveMessage(appName: "Pages").contains("Pages"))
    }

    // MARK: Caps

    @Test func totalWindowsAreCapped() async {
        let system = FakeWindowSystem()
        system.pids = [100]
        let count = LinkLimits.maxWindowsPerSnapshot + 200
        var states: [AXWindowState] = []
        var records: [CGWindowRecord] = []
        for index in 0..<count {
            states.append(axWindow(100, UInt64(index + 1), cg: UInt32(index + 1), frame: rect(Double(index) * 200, 0, 100, 100)))
            records.append(cgRecord(UInt32(index + 1), 100, bounds: rect(Double(index) * 200, 0, 100, 100)))
        }
        system.setAX(100, states)
        system.cg = records
        let (tracker, _) = await makeTracker(system)
        await tracker.reconcile()
        let snapshot = await tracker.snapshot()
        #expect(snapshot.windows.count <= LinkLimits.maxWindowsPerSnapshot)
        #expect(snapshot.windows.count <= WindowTracker.maxManagedWindowsPerApp)
    }

    @Test func titlesAreBoundedForTheWire() async {
        let system = oneWindow()
        system.setAX(100, [axWindow(100, 1, cg: 10, title: String(repeating: "é", count: 3000))])
        let (tracker, _) = await makeTracker(system)
        await tracker.reconcile()
        #expect(await tracker.snapshot().windows[0].title.utf8.count <= LinkLimits.maxTitleBytes)
    }

    @Test func nonStandardWindowsAreNotManaged() async {
        let system = oneWindow()
        system.setAX(100, [axWindow(100, 1, cg: 10), AXWindowState(token: AXWindowToken(pid: 100, id: 2), frame: rect(0, 0, 10, 10), role: "AXButton")])
        let (tracker, _) = await makeTracker(system)
        await tracker.reconcile()
        #expect(await tracker.snapshot().windows.count == 1)
    }

    // MARK: Messages and actions

    @Test func eventsConvertToLinkMessages() async {
        let system = oneWindow()
        let (tracker, recorder) = await makeTracker(system)
        await tracker.reconcile()
        let messages = recorder.events.compactMap(\.message)
        #expect(messages.count == 2)
        if case .windowCreated = messages[0] {} else { Issue.record("first message should be window.created") }
        if case .windowOrder = messages[1] {} else { Issue.record("second message should be window.order") }
        #expect(WindowTrackerEvent.unresponsive(pid: 1, isUnresponsive: true).message == nil)
    }

    @Test func linkSnapshotCarriesWindowsAndApps() async {
        let system = oneWindow()
        let (tracker, _) = await makeTracker(system)
        await tracker.reconcile()
        let snapshot = await tracker.linkSnapshot(apps: [])
        #expect(snapshot.windows.count == 1 && snapshot.activeWindow == snapshot.windows[0].id)
    }

    @Test func setFrameThroughTheTrackerPublishesTheResult() async throws {
        let system = oneWindow()
        let (tracker, recorder) = await makeTracker(system)
        await tracker.reconcile()
        let id = await tracker.snapshot().windows[0].id
        _ = recorder.take()
        let result = try await tracker.setFrame(window: id, to: rect(10, 20, 700, 500))
        #expect(result.isExact)
        #expect(await tracker.snapshot().windows[0].frame == rect(10, 20, 700, 500))
        await #expect(throws: WindowSystemError.windowGone) { try await tracker.setFrame(window: WindowID(999), to: rect(0, 0, 10, 10)) }
    }

    @Test func commandsReachTheSystem() async throws {
        let system = oneWindow()
        let (tracker, _) = await makeTracker(system)
        await tracker.reconcile()
        let id = await tracker.snapshot().windows[0].id
        try await tracker.perform(.raise, on: id)
        try await tracker.perform(.minimise, on: id)
        #expect(await tracker.snapshot().windows[0].flags.contains(.minimised))
        try await tracker.restoreFromMinimised(window: id)
        try await tracker.perform(.zoom, on: id)
        try await tracker.perform(.close, on: id)
        #expect(system.calls == ["raise", "minimise true", "minimise false", "zoom", "close"])
        #expect(await tracker.snapshot().windows.isEmpty)
    }

    @Test func startConsumesSystemEventsAndStopFinishesStreams() async {
        let system = oneWindow()
        let tracker = WindowTracker(system: system)
        await tracker.start(reconcileInterval: .seconds(3600))
        #expect(await tracker.snapshot().windows.count == 1)
        let stream = await tracker.events()
        system.setAX(100, [axWindow(100, 1, cg: 10, frame: rect(5, 5, 800, 600), focused: true)])
        system.send(.ax(pid: 100, .windowMoved))
        var iterator = stream.makeAsyncIterator()
        let event = await iterator.next()
        if case .updated(let update) = event { #expect(update.frame == rect(5, 5, 800, 600)) } else { Issue.record("expected updated, got \(String(describing: event))") }
        await tracker.stop()
        #expect(await iterator.next() == nil)
    }
}

@Suite(.timeLimit(.minutes(2))) struct FrameSetterTests {
    func system(enhanced: Bool?) -> (FakeWindowSystem, AXWindowToken) {
        let system = FakeWindowSystem()
        system.pids = [100]
        system.setAX(100, [axWindow(100, 1, cg: 10)])
        system.setEnhanced(100, enhanced)
        return (system, AXWindowToken(pid: 100, id: 1))
    }

    @Test func recipeOrderAndEnhancedUIRestore() async throws {
        let (system, token) = system(enhanced: true)
        let result = try await FrameSetter.setFrame(rect(10, 20, 640, 480), of: token, system: system)
        #expect(result.isExact && result.actual == rect(10, 20, 640, 480))
        #expect(system.calls == ["get enhanced", "set enhanced false", "position", "size", "position", "set enhanced true"])
        #expect(system.enhancedValue(100) == true)
    }

    @Test func enhancedUIAlreadyOffIsLeftAlone() async throws {
        let (system, token) = system(enhanced: false)
        _ = try await FrameSetter.setFrame(rect(0, 0, 100, 100), of: token, system: system)
        #expect(!system.calls.contains { $0.hasPrefix("set enhanced") })
        #expect(system.enhancedValue(100) == false)
    }

    @Test func appsWithoutEnhancedUIAreFine() async throws {
        let (system, token) = system(enhanced: nil)
        let result = try await FrameSetter.setFrame(rect(0, 0, 100, 100), of: token, system: system)
        #expect(result.isExact)
        #expect(!system.calls.contains { $0.hasPrefix("set enhanced") })
    }

    @Test func enhancedUIIsRestoredWhenAWriteFails() async {
        let (system, token) = system(enhanced: true)
        system.failSetSize = .timeout
        await #expect(throws: WindowSystemError.timeout) { try await FrameSetter.setFrame(rect(0, 0, 100, 100), of: token, system: system) }
        #expect(system.enhancedValue(100) == true)
        #expect(system.calls.last == "set enhanced true")
    }

    @Test func enhancedUIIsRestoredWhenTheWindowDisappears() async {
        let (system, token) = system(enhanced: true)
        system.setAX(100, [])
        await #expect(throws: WindowSystemError.windowGone) { try await FrameSetter.setFrame(rect(0, 0, 100, 100), of: token, system: system) }
        #expect(system.enhancedValue(100) == true)
    }

    @Test func readBackMismatchIsReported() async throws {
        let (system, token) = system(enhanced: false)
        system.maxSize = LinkSize(width: 500, height: 400)
        let result = try await FrameSetter.setFrame(rect(10, 10, 900, 700), of: token, system: system)
        #expect(!result.isExact)
        #expect(result.requested == rect(10, 10, 900, 700))
        #expect(result.actual == rect(10, 10, 500, 400))
    }

    @Test func invalidTargetsAreRejectedBeforeAnyWrite() async {
        let (system, token) = system(enhanced: true)
        await #expect(throws: WindowSystemError.unsupported) { try await FrameSetter.setFrame(rect(0, 0, 0, 100), of: token, system: system) }
        await #expect(throws: WindowSystemError.unsupported) { try await FrameSetter.setFrame(rect(.nan, 0, 100, 100), of: token, system: system) }
        await #expect(throws: WindowSystemError.unsupported) { try await FrameSetter.setFrame(rect(0, 0, 1e12, 100), of: token, system: system) }
        #expect(system.calls.isEmpty)
    }

    @Test func tolerance() {
        #expect(FrameSetter.matches(rect(0, 0, 100, 100), rect(0.5, -0.5, 100.9, 99.2)))
        #expect(!FrameSetter.matches(rect(0, 0, 100, 100), rect(0, 0, 102, 100)))
    }
}
#endif
