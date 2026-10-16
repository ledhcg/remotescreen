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

    /// Fails closed: true only when the topmost on-screen window under `point` is `window` itself or another window of the same
    /// process (its own menu, popover, sheet or tooltip). Any other window on top, whatever its layer or alpha (a floating
    /// panel, a notification, a system dialog, an invisible overlay that would catch the click), makes this false so the
    /// injector raises the target first. No layer is skipped: there is no click-through system layer the helper may assume.
    public func isFrontmost(_ window: WindowID, at point: LinkPoint) async -> Bool {
        guard let number = await tracker.cgWindowNumber(of: window), let info = await tracker.info(of: window) else { return false }
        // CGWindowList is ordered front to back: decide on the first on-screen window under the point.
        for record in system.cgWindows() where record.isOnScreen && Self.contains(record.bounds, point) {
            if record.id == number { return true }
            guard record.pid == info.pid else { return false }
            // Same app: only the target's own transient surfaces count, never another of the app's windows (a document the
            // session was not given).
            // A surface that just appeared (a menu opened a moment ago) may not be tracked yet: re-read that app once, then
            // decide. Still unknown means unverified, and unverified is refused.
            var other = await tracker.trackedWindow(forCGNumber: record.id)
            if other == nil {
                await tracker.reconcile(only: [info.pid])
                other = await tracker.trackedWindow(forCGNumber: record.id)
            }
            guard let other else { return false }
            return other.kind == .transient && other.parentID == window
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
