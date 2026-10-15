import Foundation
import LinkProtocol

/// One window as the client knows it.
public struct WindowState: Sendable, Equatable {
    public var info: LinkWindowInfo
    /// What can be done to the window, once the helper has sent `window.capabilities`. Not part of a snapshot.
    public var capabilities: LinkWindowCapabilities?
    /// State version at which `info` was last changed. A `window.updated` with an older or equal version is stale.
    public var version: UInt64

    public init(info: LinkWindowInfo, capabilities: LinkWindowCapabilities? = nil, version: UInt64 = 0) {
        self.info = info
        self.capabilities = capabilities
        self.version = version
    }

    public var id: WindowID { info.id }
    public var title: String { info.title }
    public var bundleID: String { info.bundleID }
    public var parentID: WindowID? { info.parentID }
    public var isManaged: Bool { info.kind == .managed }
    public var isTransient: Bool { info.kind == .transient }
    public var isMinimised: Bool { info.flags.contains(.minimised) }
}

/// Why the client should ask the helper for a fresh `snapshot` (by sending `resume` or reconnecting).
public enum ResyncReason: Sendable, Equatable {
    /// A delta arrived before any snapshot.
    case noSnapshot
    /// A delta refers to a window this client does not have.
    case unknownWindow(WindowID)
    /// A new window names a parent this client does not have, or itself.
    case unknownParent(WindowID)
    /// A window announcement is out of range (frame, scale) and was rejected.
    case invalidWindow(WindowID)
    /// Taking the window or app would exceed `LinkLimits`.
    case capacityExceeded
}

/// Result of applying one message to a `RemoteWorkspace`.
public struct WorkspaceChange: Sendable, Equatable {
    /// True when the visible model changed.
    public var didChange: Bool
    /// Set when the model can no longer be trusted to match the helper. The caller requests a snapshot.
    public var resync: ResyncReason?

    public init(didChange: Bool, resync: ResyncReason? = nil) {
        self.didChange = didChange
        self.resync = resync
    }

    public static let unchanged = WorkspaceChange(didChange: false)
}

/// The client's copy of the Mac's apps and windows: a `snapshot` replaces everything, deltas keep it current.
///
/// Deterministic and free of I/O. Rules for hostile or out-of-order input:
/// - A delta before a snapshot is ignored and asks for a resync.
/// - `window.updated` with `stateVersion <=` the window's own version is stale and ignored (no resync).
///   `window.created` and `window.destroyed` carry no version, so gaps cannot be detected by number; unknown ids are the signal.
/// - `window.updated` / `window.capabilities` for an unknown id, `window.created` with an unknown parent, over-cap counts and
///   invalid geometry reject the delta and ask for a resync. `window.destroyed` of an unknown id is a no-op (a window can be
///   created and destroyed between two snapshots).
/// - A snapshot is trusted as a whole but sanitised: duplicate ids keep the first, counts are truncated to `LinkLimits`, parents
///   that are unknown or form a cycle are cleared.
/// - A window that is created again with a known id replaces the old entry in place.
/// - Destroying a window destroys its transient descendants and detaches its managed children.
/// - A new window goes to the front of the z-order.
public struct RemoteWorkspace: Sendable, Equatable {
    public private(set) var stateVersion: UInt64 = 0
    public private(set) var hasSnapshot = false
    public private(set) var apps: [AppRef: LinkAppInfo] = [:]
    public private(set) var windows: [WindowID: WindowState] = [:]
    /// Front to back.
    public private(set) var zOrder: [WindowID] = []
    public private(set) var activeWindow: WindowID?

    public init() {}

    // MARK: Applying messages

    /// Applies a message from the helper. Messages that do not affect the workspace are ignored.
    @discardableResult
    public mutating func apply(_ message: LinkMessage) -> WorkspaceChange {
        switch message {
        case .snapshot(let snapshot): return apply(snapshot: snapshot)
        case .windowCreated(let info): return applyCreated(info)
        case .windowUpdated(let update): return apply(update: update)
        case .windowDestroyed(let id): return applyDestroyed(id)
        case .windowOrder(let ids, let active): return applyOrder(ids: ids, active: active)
        case .windowCapabilities(let id, let capabilities): return applyCapabilities(id, capabilities)
        case .appsChanged(let change, let app): return applyAppChange(change, app)
        default: return .unchanged
        }
    }

    /// Drops everything, for example when the connection is lost and the old state may be wrong.
    public mutating func reset() { self = RemoteWorkspace() }

    @discardableResult
    public mutating func apply(snapshot: LinkSnapshot) -> WorkspaceChange {
        var newWindows: [WindowID: WindowState] = [:]
        var order: [WindowID] = []
        for info in snapshot.windows where newWindows.count < LinkLimits.maxWindowsPerSnapshot {
            guard newWindows[info.id] == nil, Self.isValid(info) else { continue }
            newWindows[info.id] = WindowState(info: info, version: snapshot.stateVersion)
            order.append(info.id)
        }
        Self.sanitizeParents(&newWindows, order: order)
        var newApps: [AppRef: LinkAppInfo] = [:]
        for app in snapshot.apps where newApps.count < LinkLimits.maxApps && newApps[app.ref] == nil {
            newApps[app.ref] = app
        }
        let newActive = snapshot.activeWindow.flatMap { newWindows[$0] != nil ? $0 : nil }
        let changed = !hasSnapshot || stateVersion != snapshot.stateVersion || apps != newApps || windows != newWindows
            || zOrder != order || activeWindow != newActive
        stateVersion = snapshot.stateVersion
        hasSnapshot = true
        apps = newApps
        windows = newWindows
        zOrder = order
        activeWindow = newActive
        return WorkspaceChange(didChange: changed)
    }

    @discardableResult
    public mutating func apply(update: LinkWindowUpdate) -> WorkspaceChange {
        guard hasSnapshot else { return WorkspaceChange(didChange: false, resync: .noSnapshot) }
        guard var state = windows[update.id] else { return WorkspaceChange(didChange: false, resync: .unknownWindow(update.id)) }
        guard update.stateVersion > state.version else { return .unchanged }
        var info = state.info
        if let frame = update.frame, frame.isValid { info.frame = frame }
        if let title = update.title { info.title = title }
        if let flags = update.flags { info.flags = flags }
        if let level = update.level { info.level = level }
        if let scale = update.scale, Self.isValid(scale: scale) { info.scale = scale }
        if let minSize = update.minSize, minSize.isValid { info.minSize = minSize }
        if let maxSize = update.maxSize, maxSize.isValid { info.maxSize = maxSize }
        let changed = info != state.info
        state.info = info
        state.version = update.stateVersion
        windows[update.id] = state
        stateVersion = max(stateVersion, update.stateVersion)
        return WorkspaceChange(didChange: changed)
    }

    private mutating func applyCreated(_ info: LinkWindowInfo) -> WorkspaceChange {
        guard hasSnapshot else { return WorkspaceChange(didChange: false, resync: .noSnapshot) }
        guard Self.isValid(info) else { return WorkspaceChange(didChange: false, resync: .invalidWindow(info.id)) }
        if let parent = info.parentID {
            // The parent must exist, and walking up from it must never come back to this window (a re-created id).
            guard parent != info.id, windows[parent] != nil, !isAncestor(info.id, of: parent) else {
                return WorkspaceChange(didChange: false, resync: .unknownParent(info.id))
            }
        }
        if var existing = windows[info.id] {
            let before = existing
            existing.info = info
            windows[info.id] = existing
            return WorkspaceChange(didChange: existing != before)
        }
        guard windows.count < LinkLimits.maxWindowsPerSnapshot else {
            return WorkspaceChange(didChange: false, resync: .capacityExceeded)
        }
        windows[info.id] = WindowState(info: info, version: stateVersion)
        zOrder.insert(info.id, at: 0)
        return WorkspaceChange(didChange: true)
    }

    private mutating func applyDestroyed(_ id: WindowID) -> WorkspaceChange {
        guard windows[id] != nil else { return .unchanged }
        remove(id)
        return WorkspaceChange(didChange: true)
    }

    private mutating func remove(_ id: WindowID) {
        for child in windows.values where child.parentID == id {
            if child.isTransient {
                remove(child.id)
            } else {
                windows[child.id]?.info.parentID = nil
            }
        }
        windows[id] = nil
        zOrder.removeAll { $0 == id }
        if activeWindow == id { activeWindow = nil }
    }

    private mutating func applyOrder(ids: [WindowID], active: WindowID?) -> WorkspaceChange {
        guard hasSnapshot else { return WorkspaceChange(didChange: false, resync: .noSnapshot) }
        var seen = Set<WindowID>()
        var order: [WindowID] = []
        var unknown: WindowID?
        for id in ids.prefix(LinkLimits.maxWindowsInOrder) {
            guard windows[id] != nil else { unknown = unknown ?? id; continue }
            if seen.insert(id).inserted { order.append(id) }
        }
        // Windows the helper did not list keep their relative order behind the listed ones.
        order += zOrder.filter { !seen.contains($0) }
        var newActive = active
        if let active, windows[active] == nil { newActive = nil; unknown = unknown ?? active }
        let changed = order != zOrder || newActive != activeWindow
        zOrder = order
        activeWindow = newActive
        return WorkspaceChange(didChange: changed, resync: unknown.map { .unknownWindow($0) })
    }

    private mutating func applyCapabilities(_ id: WindowID, _ capabilities: LinkWindowCapabilities) -> WorkspaceChange {
        guard hasSnapshot else { return WorkspaceChange(didChange: false, resync: .noSnapshot) }
        guard windows[id] != nil else { return WorkspaceChange(didChange: false, resync: .unknownWindow(id)) }
        let changed = windows[id]?.capabilities != capabilities
        windows[id]?.capabilities = capabilities
        return WorkspaceChange(didChange: changed)
    }

    private mutating func applyAppChange(_ change: LinkAppChange, _ app: LinkAppInfo) -> WorkspaceChange {
        guard hasSnapshot else { return WorkspaceChange(didChange: false, resync: .noSnapshot) }
        let before = apps
        switch change {
        case .terminated:
            apps[app.ref] = nil
        case .launched, .activated:
            guard apps[app.ref] != nil || apps.count < LinkLimits.maxApps else {
                return WorkspaceChange(didChange: false, resync: .capacityExceeded)
            }
            var app = app
            if change == .activated {
                app.isActive = true
                for ref in apps.keys where ref != app.ref { apps[ref]?.isActive = false }
            }
            apps[app.ref] = app
        }
        return WorkspaceChange(didChange: apps != before)
    }

    // MARK: Validation

    private static func isValid(scale: Double) -> Bool { scale.isFinite && scale > 0 && scale <= LinkLimits.maxScale }

    private static func isValid(_ info: LinkWindowInfo) -> Bool {
        info.frame.isValid && isValid(scale: info.scale) && info.minSize.isValid && info.maxSize.isValid
    }

    /// Clears parents that are unknown, self-referencing or part of a cycle. Walks in z-order so the result is deterministic.
    private static func sanitizeParents(_ windows: inout [WindowID: WindowState], order: [WindowID]) {
        for id in order {
            var current = id
            var steps = 0
            while let parent = windows[current]?.info.parentID {
                steps += 1
                if windows[parent] == nil || steps > windows.count || parent == id {
                    windows[current]?.info.parentID = nil
                    break
                }
                current = parent
            }
        }
    }

    /// True when `ancestor` is on the parent chain above `id` (bounded, so a corrupt chain cannot loop).
    private func isAncestor(_ ancestor: WindowID, of id: WindowID) -> Bool {
        var current = id
        for _ in 0...windows.count {
            guard let parent = windows[current]?.parentID else { return false }
            if parent == ancestor { return true }
            current = parent
        }
        return true
    }

    // MARK: Queries

    public func window(_ id: WindowID) -> WindowState? { windows[id] }

    public func app(bundleID: String) -> LinkAppInfo? {
        apps.values.filter { $0.bundleID == bundleID }.min { $0.ref < $1.ref }
    }

    /// Apps sorted by name (case-insensitive), then bundle id, then ref.
    public var sortedApps: [LinkAppInfo] {
        apps.values.sorted { a, b in
            let (x, y) = (a.name.lowercased(), b.name.lowercased())
            if x != y { return x < y }
            if a.bundleID != b.bundleID { return a.bundleID < b.bundleID }
            return a.ref < b.ref
        }
    }

    /// All windows, front to back.
    public var orderedWindows: [WindowState] { zOrder.compactMap { windows[$0] } }

    /// Managed windows of an app, front to back.
    public func managedWindows(bundleID: String) -> [WindowState] {
        orderedWindows.filter { $0.isManaged && $0.bundleID == bundleID }
    }

    /// Managed windows of an app in a stable order (by window id, which the helper never reuses), for index hints.
    func stableManagedWindows(bundleID: String) -> [WindowState] {
        windows.values.filter { $0.isManaged && $0.bundleID == bundleID }.sorted { $0.id < $1.id }
    }

    /// Direct children of a window, front to back. For a managed window these are its sheets, popovers and panels.
    public func children(of id: WindowID) -> [WindowState] {
        orderedWindows.filter { $0.parentID == id }
    }

    /// Transient surfaces under a window, including nested ones, front to back.
    public func transientSurfaces(of id: WindowID) -> [WindowState] {
        var reachable: Set<WindowID> = [id]
        var grew = true
        var rounds = 0
        // Parents can sit anywhere in z-order, so iterate to a fixed point (bounded by the window count).
        while grew, rounds <= windows.count {
            grew = false
            rounds += 1
            for window in windows.values where window.isTransient && !reachable.contains(window.id) {
                if let parent = window.parentID, reachable.contains(parent) {
                    reachable.insert(window.id)
                    grew = true
                }
            }
        }
        reachable.remove(id)
        return orderedWindows.filter { reachable.contains($0.id) }
    }

    /// The managed window a transient surface belongs to (the window itself when it has no parent), or `nil` when the chain is broken.
    public func rootWindow(of id: WindowID) -> WindowState? {
        var current = id
        for _ in 0...windows.count {
            guard let state = windows[current] else { return nil }
            guard let parent = state.parentID else { return state }
            current = parent
        }
        return nil
    }

    /// Windows to show in the launcher: managed windows grouped by app name, then front to back inside an app.
    public var windowsForLauncher: [WindowState] {
        let zIndex = Dictionary(uniqueKeysWithValues: zOrder.enumerated().map { ($1, $0) })
        func appName(_ window: WindowState) -> String {
            app(bundleID: window.bundleID)?.name.lowercased() ?? window.bundleID.lowercased()
        }
        return windows.values.filter(\.isManaged).sorted { a, b in
            let (x, y) = (appName(a), appName(b))
            if x != y { return x < y }
            if a.bundleID != b.bundleID { return a.bundleID < b.bundleID }
            let (za, zb) = (zIndex[a.id] ?? Int.max, zIndex[b.id] ?? Int.max)
            if za != zb { return za < zb }
            return a.id < b.id
        }
    }

    /// Equal apps, windows (without capabilities and versions), z-order and active window. Used to check that deltas converge
    /// to the same state as a snapshot.
    public func hasSameContent(as other: RemoteWorkspace) -> Bool {
        apps == other.apps && zOrder == other.zOrder && activeWindow == other.activeWindow
            && windows.mapValues(\.info) == other.windows.mapValues(\.info)
    }
}
