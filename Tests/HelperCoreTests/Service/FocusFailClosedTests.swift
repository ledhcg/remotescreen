#if os(macOS)
import Foundation
import LinkProtocol
import Testing
@testable import HelperCore

@Suite struct FocusFailClosedTests {
    func setup(cg: [CGWindowRecord]) async -> (TrackerWindowFocuser, WindowID, FakeWindowSystem, WindowTracker) {
        let system = FakeWindowSystem()
        system.pids = [10]
        system.frontmost = 10
        system.cg = [cgRecord(501, 10)]
        system.setAX(10, [axWindow(10, 1, cg: 501, focused: true)])
        let tracker = WindowTracker(system: system)
        await tracker.reconcile()
        let id = await tracker.snapshot().windows[0].id
        system.cg = cg
        return (TrackerWindowFocuser(tracker: tracker, system: system, workspace: FakeWorkspace()), id, system, tracker)
    }
    let point = LinkPoint(x: 150, y: 150)

    @Test func targetTopmostIsTrue() async {
        let (f, id, _, _) = await setup(cg: [cgRecord(501, 10)])
        #expect(await f.isFrontmost(id, at: point))
    }

    @Test func unknownWindowServerNumberFailsClosed() async {
        let system = FakeWindowSystem()
        system.pids = [10]; system.frontmost = 10
        system.cg = [cgRecord(501, 10)]
        system.setAX(10, [axWindow(10, 1, cg: 501, focused: true)])
        let tracker = WindowTracker(system: system)
        await tracker.reconcile()
        let id = await tracker.snapshot().windows[0].id
        // The number disappears: no CG record and no AX number. The window is still the active one, which must not be enough.
        system.cg = []
        system.setAX(10, [axWindow(10, 1, cg: nil, focused: true)])
        await tracker.reconcile()
        let after = await tracker.snapshot().windows[0].id
        _ = id
        let f = TrackerWindowFocuser(tracker: tracker, system: system, workspace: FakeWorkspace())
        system.cg = [cgRecord(501, 10)]
        #expect(await tracker.cgWindowNumber(of: after) == nil)
        #expect(await tracker.snapshot().activeWindow == after)
        #expect(await f.isFrontmost(after, at: point) == false)
        #expect(await f.isFrontmost(WindowID(999), at: point) == false)
    }

    @Test func foreignWindowOfAHigherLayerFailsClosed() async {
        let (f, id, _, _) = await setup(cg: [cgRecord(900, 77, bounds: rect(0, 0, 1000, 1000), layer: 25), cgRecord(501, 10)])
        #expect(await f.isFrontmost(id, at: point) == false)
    }

    @Test func invisibleForeignOverlayFailsClosed() async {
        let (f, id, _, _) = await setup(cg: [cgRecord(900, 77, bounds: rect(0, 0, 1000, 1000), layer: 3, alpha: 0), cgRecord(501, 10)])
        #expect(await f.isFrontmost(id, at: point) == false)
    }

    @Test func ownProcessPopupOnTopIsAccepted() async {
        let (f, id, _, _) = await setup(cg: [cgRecord(777, 10, bounds: rect(140, 140, 100, 100), layer: 101), cgRecord(501, 10)])
        #expect(await f.isFrontmost(id, at: point))
    }

    @Test func foreignWindowElsewhereDoesNotMatter() async {
        let (f, id, _, _) = await setup(cg: [cgRecord(900, 77, bounds: rect(2000, 2000, 50, 50), layer: 25), cgRecord(501, 10)])
        #expect(await f.isFrontmost(id, at: point))
    }

    @Test func offScreenForeignWindowIsIgnored() async {
        let (f, id, _, _) = await setup(cg: [cgRecord(900, 77, bounds: rect(0, 0, 1000, 1000), onScreen: false), cgRecord(501, 10)])
        #expect(await f.isFrontmost(id, at: point))
    }
}
#endif
