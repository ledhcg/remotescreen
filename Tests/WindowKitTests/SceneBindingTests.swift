import Foundation
import Localization
import LinkProtocol
import Testing
@testable import WindowKit

@Suite("Window matching", .serialized)
struct WindowMatchingTests {
    @Test func exactTitleBeatsEverything() {
        let ws = workspace([makeWindow(1, title: "Notes"), makeWindow(2, title: "Shopping"), makeWindow(3, title: "Ideas")])
        let match = ws.bestMatch(for: WindowMatchQuery(bundleID: "com.example.app", title: "Ideas", indexHint: 0))
        #expect(match?.id == 3)
        #expect(match?.score == 100 + 12 - 4 * 2)
    }

    @Test func titleIgnoresCaseDiacriticsAndSpace() {
        #expect(WindowMatchScoring.titleScore("Tài liệu", "  tai lieu ") == 80)
        #expect(WindowMatchScoring.titleScore("Report.pdf", "Report.pdf — Page 2") == 40)
        #expect(WindowMatchScoring.titleScore("A", "B") == 0)
        #expect(WindowMatchScoring.titleScore("", "") == 30)
        #expect(WindowMatchScoring.titleScore("", "Something") == 0)
    }

    @Test func renamedWindowAtTheSameIndexStillMatches() {
        let ws = workspace([makeWindow(1, title: "Untitled 2"), makeWindow(2, title: "Other")])
        let query = WindowMatchQuery(bundleID: "com.example.app", title: "Untitled", indexHint: 1)
        // Title "Untitled" is contained in "Untitled 2" (40) but the index points at window 2 (25): the title wins.
        #expect(ws.bestMatch(for: query)?.id == 1)
        let renamed = WindowMatchQuery(bundleID: "com.example.app", title: "Completely different", indexHint: 1)
        #expect(ws.bestMatch(for: renamed)?.id == 2, "same position is acceptable on its own")
    }

    @Test func unrelatedWindowFarAwayIsRejected() {
        let ws = workspace((1...6).map { makeWindow(UInt32($0), title: "W\($0)") })
        let query = WindowMatchQuery(bundleID: "com.example.app", title: "Gone", indexHint: 40)
        #expect(ws.bestMatch(for: query) == nil)
        #expect(!ws.rankedMatches(for: query).isEmpty, "ranking still lists candidates")
    }

    @Test func otherAppsAndTransientsNeverMatch() {
        let ws = workspace([makeWindow(1, bundle: "other", title: "Notes"), makeWindow(2, title: "Notes", parent: 3, kind: .transient), makeWindow(3, title: "x")])
        let query = WindowMatchQuery(bundleID: "com.example.app", title: "Notes", indexHint: 0)
        #expect(ws.rankedMatches(for: query).map(\.id) == [3])
    }

    @Test func tiesGoToTheLowerWindowId() {
        let ws = workspace([makeWindow(9, title: "Same"), makeWindow(4, title: "Same")])
        // Indexes by id order: 4 is index 0, 9 is index 1; a hint of 0 prefers 4 on index, and equal titles tie otherwise.
        #expect(ws.bestMatch(for: WindowMatchQuery(bundleID: "com.example.app", title: "Same", indexHint: 0))?.id == 4)
        let tie = WindowMatchQuery(bundleID: "com.example.app", title: "Same", indexHint: 99)
        #expect(ws.rankedMatches(for: tie).map(\.id) == [4, 9])
    }

    @Test func excludedWindowsAreSkipped() {
        let ws = workspace([makeWindow(1, title: "A"), makeWindow(2, title: "A")])
        let query = WindowMatchQuery(bundleID: "com.example.app", title: "A", indexHint: 0)
        #expect(ws.bestMatch(for: query, excluding: [1])?.id == 2)
        #expect(ws.bestMatch(for: query, excluding: [1, 2]) == nil)
    }

    @Test func matchQueryUsesCreationOrderNotZOrder() {
        var ws = workspace([makeWindow(5, title: "five"), makeWindow(2, title: "two")])
        #expect(ws.matchQuery(for: 5)?.indexHint == 1)
        ws.apply(.windowOrder(ids: [2, 5], active: nil))
        #expect(ws.matchQuery(for: 5)?.indexHint == 1)
        #expect(ws.matchQuery(for: 404) == nil)
    }
}

@Suite("Scene bindings", .serialized)
struct SceneBindingTests {
    init() { Localization.forcedLanguage = "en" }

    @Test func openingAnOpenWindowFocusesTheExistingScene() {
        let ws = workspace([makeWindow(1), makeWindow(2)])
        var bindings = SceneBindings()
        let r1 = bindings.open(window: 1, in: SceneID("a"), workspace: ws)
        #expect(r1 == .bound)
        let r2 = bindings.open(window: 1, in: SceneID("b"), workspace: ws)
        #expect(r2 == .focusExisting(SceneID("a")))
        #expect(bindings.state(of: SceneID("b")) == nil)
        // The same scene asking again is not a duplicate.
        let r3 = bindings.open(window: 1, in: SceneID("a"), workspace: ws)
        #expect(r3 == .bound)
        #expect(bindings.scene(for: 1) == SceneID("a"))
        let r4 = bindings.open(window: 2, in: SceneID("b"), workspace: ws)
        #expect(r4 == .bound)
        #expect(bindings.scenes == [SceneID("a"), SceneID("b")])
    }

    @Test func destroyedWindowTurnsTheSceneIntoAPlaceholderWithAHint() {
        var ws = workspace([makeWindow(1, title: "Report"), makeWindow(2)])
        var bindings = SceneBindings()
        bindings.open(window: 1, in: SceneID("a"), workspace: ws)
        ws.apply(.windowUpdated(LinkWindowUpdate(id: 1, stateVersion: 2, title: "Report v2")))
        #expect(bindings.reconcile(with: ws).isEmpty)
        ws.apply(.windowDestroyed(1))
        let r5 = bindings.reconcile(with: ws)
        #expect(r5 == [SceneID("a")])
        guard case .windowClosed(let hint)? = bindings.state(of: SceneID("a")) else {
            Issue.record("expected windowClosed")
            return
        }
        #expect(hint.title == "Report v2", "the hint carries the last title")
        #expect(hint.bundleID == "com.example.app")
        #expect(bindings.state(of: SceneID("a"))?.placeholderMessage == "This window was closed on the Mac.")
        #expect(bindings.state(of: SceneID("a"))?.placeholderHint == "Choose another window from the launcher.")
        #expect(bindings.scene(for: 1) == nil, "a closed window frees its id")
        #expect(bindings.reconcile(with: ws).isEmpty, "stable once closed")
    }

    @Test func closedSceneCanRebindWhenTheWindowReturns() {
        var ws = workspace([makeWindow(1, title: "Report")])
        var bindings = SceneBindings()
        bindings.open(window: 1, in: SceneID("a"), workspace: ws)
        ws.apply(.windowDestroyed(1))
        bindings.reconcile(with: ws)
        let r6 = bindings.rebind(scene: SceneID("a"), workspace: ws)
        #expect(!r6)
        ws.apply(.windowCreated(makeWindow(7, title: "Report")))
        #expect(bindings.reconcile(with: ws).isEmpty, "reconcile never rebinds a closed scene by itself")
        let r7 = bindings.rebind(scene: SceneID("a"), workspace: ws)
        #expect(r7)
        #expect(bindings.state(of: SceneID("a")) == .bound(7))
    }

    @Test func restoreWaitsForTheSnapshotThenBinds() {
        var bindings = SceneBindings()
        let query = WindowMatchQuery(bundleID: "com.example.app", title: "Report", indexHint: 1)
        var ws = RemoteWorkspace()
        let r8 = bindings.restore(scene: SceneID("a"), query: query, workspace: ws)
        #expect(r8 == .restoring(query))
        #expect(bindings.state(of: SceneID("a"))?.placeholderMessage == "Looking for this window on the Mac…")
        #expect(bindings.reconcile(with: ws).isEmpty, "still no snapshot")
        ws.apply(.snapshot(makeSnapshot(windows: [makeWindow(3, title: "Other"), makeWindow(4, title: "Report")])))
        let r9 = bindings.reconcile(with: ws)
        #expect(r9 == [SceneID("a")])
        #expect(bindings.state(of: SceneID("a")) == .bound(4))
        #expect(bindings.restorationQuery(for: SceneID("a"))?.indexHint == 1)
    }

    @Test func restoreFallsBackToAPlaceholderWhenNothingMatches() {
        let ws = workspace([makeWindow(1, bundle: "other")])
        var bindings = SceneBindings()
        let query = WindowMatchQuery(bundleID: "com.example.app", title: "Report", indexHint: 0)
        let r10 = bindings.restore(scene: SceneID("a"), query: query, workspace: ws)
        #expect(r10 == .windowClosed(reopenHint: query))
        #expect(bindings.restorationQuery(for: SceneID("a")) == query)
    }

    @Test func twoScenesNeverRestoreToTheSameWindow() {
        let ws = workspace([makeWindow(1, title: "Doc"), makeWindow(2, title: "Doc")])
        var bindings = SceneBindings()
        let query = WindowMatchQuery(bundleID: "com.example.app", title: "Doc", indexHint: 0)
        bindings.restore(scene: SceneID("a"), query: query, workspace: ws)
        bindings.restore(scene: SceneID("b"), query: query, workspace: ws)
        #expect(bindings.state(of: SceneID("a")) == .bound(1))
        #expect(bindings.state(of: SceneID("b")) == .bound(2))
        bindings.remove(scene: SceneID("a"))
        #expect(bindings.scene(for: 1) == nil)
    }

    @Test func transientWindowCountsAsGone() {
        var ws = workspace([makeWindow(1)])
        var bindings = SceneBindings()
        bindings.open(window: 1, in: SceneID("a"), workspace: ws)
        // The helper cannot turn a managed window into a surface, but a corrupt update must not leave a bound transient.
        ws.apply(.snapshot(makeSnapshot(version: 2, windows: [makeWindow(1, kind: .transient)])))
        let r11 = bindings.reconcile(with: ws)
        #expect(r11 == [SceneID("a")])
    }

    @Test func vietnamesePlaceholdersExist() {
        func vi(_ key: String) -> String { Localization.string(key, bundle: localizationBundle, language: "vi") }
        #expect(vi("This window was closed on the Mac.") == "Cửa sổ này đã được đóng trên máy Mac.")
        #expect(vi("Looking for this window on the Mac…") == "Đang tìm cửa sổ này trên máy Mac…")
    }
}
