#if os(macOS)
import Foundation
import LinkProtocol

// Adapters that implement the seams other modules expect on top of `WindowTracker` and `WindowSystem`:
//  * `WindowGeometryProvider` and `WindowFocuser` for `InputInjector` (InputProtocols.swift),
//  * `WindowFrameSetter` for `Stage` (StageTypes.swift).

/// Window geometry for the injector, read live from the app so a window that moved a moment ago is still hit correctly.
public struct TrackerWindowGeometry: WindowGeometryProvider {
    private let tracker: WindowTracker
    public init(tracker: WindowTracker) { self.tracker = tracker }
    public func contentFrame(of window: WindowID) async -> LinkRect? { await tracker.liveFrame(of: window) }
}

/// Focus handling for the injector: "is W topmost at this point", "which window has keyboard focus", "raise and activate".
public struct TrackerWindowFocuser: WindowFocuser {
    private let tracker: WindowTracker
    private let system: any WindowSystem
    private let workspace: any WorkspaceAccess

    public init(tracker: WindowTracker, system: any WindowSystem, workspace: any WorkspaceAccess) {
        self.tracker = tracker; self.system = system; self.workspace = workspace
    }

    public func isFrontmost(_ window: WindowID, at point: LinkPoint) async -> Bool {
        guard let number = await tracker.cgWindowNumber(of: window) else {
            // No window-server number (the private AX call failed and no CGWindowList record matched): the active window of the
            // frontmost app is the best guess.
            return await tracker.snapshot().activeWindow == window
        }
        // CGWindowList is ordered front to back: the first on-screen, visible window under the point is the topmost one.
        for record in system.cgWindows() where record.isOnScreen && record.alpha > 0.01 && record.layer < 20 {
            if Self.contains(record.bounds, point) { return record.id == number }
        }
        return false
    }

    public func frontmostWindow() async -> WindowID? {
        let snapshot = await tracker.snapshot()
        guard let active = snapshot.activeWindow else { return nil }
        // The tracker's active window belongs to the frontmost app; double-check against the system so a stale snapshot does
        // not send keys to the wrong app.
        guard let info = snapshot.windows.first(where: { $0.id == active }), system.frontmostPID() == info.pid else { return nil }
        return active
    }

    public func raiseAndActivate(_ window: WindowID) async {
        guard let info = await tracker.info(of: window) else { return }
        if info.flags.contains(.minimised) { try? await tracker.restoreFromMinimised(window: window) }
        _ = workspace.activate(pid: info.pid)
        try? await tracker.perform(.raise, on: window)
    }

    static func contains(_ rect: LinkRect, _ point: LinkPoint) -> Bool {
        point.x >= rect.origin.x && point.x < rect.origin.x + rect.size.width
            && point.y >= rect.origin.y && point.y < rect.origin.y + rect.size.height
    }
}

/// Stage's view of windows. `StageWindowKey` (pid + window-server number) is resolved to the tracker's `WindowID` on every call,
/// so a window that disappeared simply returns nil.
public struct TrackerFrameSetter: WindowFrameSetter {
    private let tracker: WindowTracker
    public init(tracker: WindowTracker) { self.tracker = tracker }

    public func currentFrame(of window: StageWindowKey) async -> LinkRect? {
        guard let id = await tracker.window(forStageKey: window) else { return nil }
        return await tracker.liveFrame(of: id)
    }

    public func setFrame(_ window: StageWindowKey, to rect: LinkRect) async -> LinkRect? {
        guard let id = await tracker.window(forStageKey: window) else { return nil }
        // The tracker uses `FrameSetter`: Enhanced UI off around the change, position-size-position, read back.
        return try? await tracker.setFrame(window: id, to: rect).actual
    }

    public func exitFullScreen(_ window: StageWindowKey) async {
        guard let id = await tracker.window(forStageKey: window) else { return }
        try? await tracker.perform(.exitFullScreen, on: id)
    }

    // `sizeLimits(of:)` keeps the protocol's default (unbounded): `WindowSystem` has no AX minimum/maximum size read yet.
}
#endif
