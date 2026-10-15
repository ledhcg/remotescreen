#if os(macOS)
import Foundation
import LinkProtocol
import os

/// What the tracker reports, shaped like the link messages. Every event except `.unresponsive` carries the new,
/// strictly increasing state version.
public enum WindowTrackerEvent: Sendable, Equatable {
    case created(LinkWindowInfo, stateVersion: UInt64)
    case updated(LinkWindowUpdate)
    case destroyed(WindowID, stateVersion: UInt64)
    /// Front-to-back order and the active window; sent whenever either changes.
    case order(ids: [WindowID], active: WindowID?, stateVersion: UInt64)
    /// An app stopped (or started again) answering accessibility requests. Its last known windows are kept.
    case unresponsive(pid: Int32, isUnresponsive: Bool)

    public var stateVersion: UInt64? {
        switch self {
        case .created(_, let version), .destroyed(_, let version), .order(_, _, let version): version
        case .updated(let update): update.stateVersion
        case .unresponsive: nil
        }
    }

    /// The wire message for this event, when it has one.
    public var message: LinkMessage? {
        switch self {
        case .created(let info, _): .windowCreated(info)
        case .updated(let update): .windowUpdated(update)
        case .destroyed(let id, _): .windowDestroyed(id)
        case .order(let ids, let active, _): .windowOrder(ids: ids, active: active)
        case .unresponsive: nil
        }
    }
}

/// Windows in front-to-back order plus the version they belong to.
public struct WindowTrackerSnapshot: Sendable, Equatable {
    public var stateVersion: UInt64
    public var windows: [LinkWindowInfo]
    public var activeWindow: WindowID?
}

/// Keeps the list of windows on the Mac: accessibility notifications give low latency, a periodic CGWindowList
/// reconciliation corrects whatever notifications missed.
///
/// Every refresh reads the current state and diffs it against what was published, so a missed or reordered
/// notification can only delay an update, never leave the state wrong. Titles are never logged.
public actor WindowTracker {
    public static let maxTrackedApps = 512
    public static let maxManagedWindowsPerApp = 256
    public static let maxTransientWindowsPerApp = 64
    /// CGWindowList layers treated as popup surfaces (menus 101, popovers, tooltips, floating helpers).
    static func isTransientLayer(_ layer: Int) -> Bool {
        // Not the Dock (20), menu bar (24) or status items (25), which belong to the system's chrome.
        (1...200).contains(layer) && ![20, 24, 25].contains(layer)
    }

    private enum Key: Hashable {
        case ax(AXWindowToken)
        case cg(UInt32)
    }

    private struct Entry {
        var id: WindowID
        var info: LinkWindowInfo
    }

    private struct Desired {
        var key: Key
        var info: LinkWindowInfo
        var zIndex: Int
        var parentKey: Key?
        var isFocusedAX = false
        var isMainAX = false
    }

    private let system: any WindowSystem
    private let log = Logger(subsystem: "app.screon.helper", category: "windows")
    private var entries: [Key: Entry] = [:]
    private var tokens: [WindowID: AXWindowToken] = [:]
    private var order: [WindowID] = []
    private var active: WindowID?
    private var axCache: [Int32: [AXWindowState]] = [:]
    private var observed: Set<Int32> = []
    private var unresponsive: Set<Int32> = []
    private var nextID: UInt32 = 1
    private var stateVersion: UInt64 = 0
    private var handlers: [@Sendable (WindowTrackerEvent) -> Void] = []
    private var subscribers: [UUID: AsyncStream<WindowTrackerEvent>.Continuation] = [:]
    private var dirty: Set<Int32> = []
    private var draining = false
    private var eventTask: Task<Void, Never>?
    private var timerTask: Task<Void, Never>?

    public init(system: any WindowSystem) { self.system = system }

    // MARK: Lifecycle

    /// Starts listening and reconciling. The first reconciliation completes before this returns.
    public func start(reconcileInterval: Duration = .seconds(1)) async {
        guard eventTask == nil else { return }
        let source = system.events()
        eventTask = Task { [weak self] in
            for await event in source {
                guard let self else { return }
                await self.handle(event)
            }
        }
        await reconcile()
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: reconcileInterval)
                guard let self, !Task.isCancelled else { return }
                await self.reconcile()
            }
        }
    }

    public func stop() {
        eventTask?.cancel(); timerTask?.cancel()
        eventTask = nil; timerTask = nil
        for continuation in subscribers.values { continuation.finish() }
        subscribers.removeAll()
    }

    /// Events from now on. Combine with `snapshot()` taken in the same actor turn to avoid gaps.
    public func events() -> AsyncStream<WindowTrackerEvent> {
        let (stream, continuation) = AsyncStream<WindowTrackerEvent>.makeStream(bufferingPolicy: .unbounded)
        let id = UUID()
        subscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSubscriber(id) }
        }
        return stream
    }

    private func removeSubscriber(_ id: UUID) { subscribers.removeValue(forKey: id) }

    /// Synchronous observer, called inside the actor for every event. Used by tests that need exact ordering.
    func observe(_ handler: @escaping @Sendable (WindowTrackerEvent) -> Void) { handlers.append(handler) }

    private func emit(_ event: WindowTrackerEvent) {
        for handler in handlers { handler(event) }
        for continuation in subscribers.values { continuation.yield(event) }
    }

    // MARK: Queries

    public func snapshot() -> WindowTrackerSnapshot {
        let byID = Dictionary(entries.values.map { ($0.id, $0.info) }, uniquingKeysWith: { first, _ in first })
        return WindowTrackerSnapshot(stateVersion: stateVersion, windows: order.compactMap { byID[$0] }, activeWindow: active)
    }

    /// `snapshot` message content; the app list comes from `AppCatalog`.
    public func linkSnapshot(apps: [LinkAppInfo]) -> LinkSnapshot {
        let current = snapshot()
        return LinkSnapshot(stateVersion: current.stateVersion, apps: apps, windows: current.windows, activeWindow: current.activeWindow)
    }

    /// Managed windows per pid, for `AppCatalog.apps(filter:windowCounts:)`.
    public func windowCounts() -> [Int32: Int] {
        var counts: [Int32: Int] = [:]
        for entry in entries.values where entry.info.kind == .managed { counts[entry.info.pid, default: 0] += 1 }
        return counts
    }

    public func info(of window: WindowID) -> LinkWindowInfo? {
        entries.values.first { $0.id == window }?.info
    }

    public func isUnresponsive(pid: Int32) -> Bool { unresponsive.contains(pid) }

    /// Status line for an app that stopped answering.
    public static func unresponsiveMessage(appName: String) -> String { tr("%@ is not responding.", appName) }

    // MARK: Actions

    /// Moves and resizes a managed window; see `FrameSetter`. The tracker publishes whatever the window ends up with.
    public func setFrame(window: WindowID, to frame: LinkRect) async throws -> FrameSetResult {
        guard let token = tokens[window] else { throw WindowSystemError.windowGone }
        let result = try await FrameSetter.setFrame(frame, of: token, system: system)
        dirty.insert(token.pid)
        await drain()
        return result
    }

    public func perform(_ command: LinkWindowCommand, on window: WindowID) async throws {
        guard let token = tokens[window] else { throw WindowSystemError.windowGone }
        switch command {
        case .raise: try await system.raise(token)
        case .close: try await system.pressClose(token)
        case .minimise: try await system.setMinimised(token, true)
        case .zoom: try await system.pressZoom(token)
        case .exitFullScreen: try await system.setFullScreen(token, false)
        }
        dirty.insert(token.pid)
        await drain()
    }

    /// Un-minimises a window (the iPad asks for it by raising a minimised window).
    public func restoreFromMinimised(window: WindowID) async throws {
        guard let token = tokens[window] else { throw WindowSystemError.windowGone }
        try await system.setMinimised(token, false)
        dirty.insert(token.pid)
        await drain()
    }

    // MARK: Events

    /// Processes one system event and returns when the resulting refresh has been applied (or is being applied by a
    /// refresh that is already running).
    public func handle(_ event: WindowSystemEvent) async {
        switch event {
        case .appTerminated(let pid):
            axCache.removeValue(forKey: pid)
            if observed.remove(pid) != nil { await system.stopObserving(pid: pid) }
            dirty.insert(pid)
        case .appLaunched(let pid), .ax(let pid, _):
            dirty.insert(pid)
        }
        await drain()
    }

    private func drain() async {
        guard !draining else { return }
        draining = true
        while !dirty.isEmpty {
            let batch = dirty
            dirty = []
            await reconcile(only: batch)
        }
        draining = false
    }

    // MARK: Reconciliation

    /// Reads the OS state and publishes the difference. `only` limits the (slow, per-app) accessibility reads to those
    /// pids; every other app keeps its last known windows. `nil` refreshes all apps.
    public func reconcile(only: Set<Int32>? = nil) async {
        let tracked = Array(system.trackablePIDs().prefix(Self.maxTrackedApps))
        let trackedSet = Set(tracked)

        for pid in axCache.keys where !trackedSet.contains(pid) { axCache.removeValue(forKey: pid) }
        for pid in observed where !trackedSet.contains(pid) {
            observed.remove(pid)
            await system.stopObserving(pid: pid)
        }
        for pid in unresponsive where !trackedSet.contains(pid) {
            unresponsive.remove(pid)
            emit(.unresponsive(pid: pid, isUnresponsive: false))
        }

        let wanted = only.map { $0.intersection(trackedSet) } ?? trackedSet
        let toFetch = wanted.union(trackedSet.filter { axCache[$0] == nil }).sorted()
        let alreadyObserved = observed
        let system = self.system
        let results = await withTaskGroup(of: (Int32, Result<[AXWindowState], WindowSystemError>).self) { group in
            for pid in toFetch {
                group.addTask {
                    if !alreadyObserved.contains(pid) { try? await system.startObserving(pid: pid) }
                    do {
                        return (pid, .success(try await system.axWindows(pid: pid)))
                    } catch {
                        return (pid, .failure(error as? WindowSystemError ?? .failed(-1)))
                    }
                }
            }
            var collected: [(Int32, Result<[AXWindowState], WindowSystemError>)] = []
            for await result in group { collected.append(result) }
            return collected
        }
        let cgWindows = system.cgWindows()
        let frontmost = system.frontmostPID()

        // Everything from here on is synchronous, so a concurrent refresh can never see half-applied state.
        for (pid, result) in results.sorted(by: { $0.0 < $1.0 }) {
            observed.insert(pid)
            switch result {
            case .success(let states):
                axCache[pid] = Array(states.prefix(Self.maxManagedWindowsPerApp * 2))
                if unresponsive.remove(pid) != nil { emit(.unresponsive(pid: pid, isUnresponsive: false)) }
            case .failure(.timeout):
                if unresponsive.insert(pid).inserted {
                    log.notice("An app stopped answering accessibility requests (pid \(pid, privacy: .public)).")
                    emit(.unresponsive(pid: pid, isUnresponsive: true))
                }
            case .failure(.windowGone):
                axCache[pid] = []
            case .failure:
                break
            }
        }
        let (desired, activeKey) = computeDesired(tracked: trackedSet, cg: cgWindows, frontmost: frontmost)
        apply(desired, activeKey: activeKey)
    }

    private static func isManagedCandidate(_ state: AXWindowState) -> Bool {
        guard state.role == "AXWindow" else { return false }
        return ["", "AXStandardWindow", "AXDialog", "AXFloatingWindow", "AXUnknown"].contains(state.subrole)
    }

    private static func frameMatches(_ a: LinkRect, _ b: LinkRect) -> Bool {
        abs(a.origin.x - b.origin.x) <= 2 && abs(a.origin.y - b.origin.y) <= 2
            && abs(a.size.width - b.size.width) <= 2 && abs(a.size.height - b.size.height) <= 2
    }

    private static func intersects(_ a: LinkRect, _ b: LinkRect) -> Bool {
        a.origin.x < b.origin.x + b.size.width && b.origin.x < a.origin.x + a.size.width
            && a.origin.y < b.origin.y + b.size.height && b.origin.y < a.origin.y + a.size.height
    }

    private static func contains(_ outer: LinkRect, _ inner: LinkRect) -> Bool {
        inner.origin.x >= outer.origin.x - 1 && inner.origin.y >= outer.origin.y - 1
            && inner.origin.x + inner.size.width <= outer.origin.x + outer.size.width + 1
            && inner.origin.y + inner.size.height <= outer.origin.y + outer.size.height + 1
    }

    private func computeDesired(tracked: Set<Int32>, cg: [CGWindowRecord], frontmost: Int32?) -> ([Desired], Key?) {
        let zIndexByCG = Dictionary(cg.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        var managed: [Desired] = []
        var transient: [Desired] = []

        for pid in tracked.sorted() {
            guard let states = axCache[pid] else { continue }
            let bundleID = HelperText.bounded(system.bundleID(forPID: pid) ?? "", maxBytes: LinkLimits.maxBundleIDBytes)
            let records = cg.filter { $0.pid == pid }
            let candidates = states.filter(Self.isManagedCandidate).prefix(Self.maxManagedWindowsPerApp)

            var matched: [AXWindowToken: CGWindowRecord] = [:]
            var taken = Set<UInt32>()
            for state in candidates {
                if let id = state.cgWindowID, let record = records.first(where: { $0.id == id }), !taken.contains(id) {
                    matched[state.token] = record
                    taken.insert(id)
                }
            }
            // The private window-number call is missing or failed: fall back to pid + frame.
            for state in candidates where matched[state.token] == nil && state.cgWindowID == nil {
                if let record = records.first(where: { !taken.contains($0.id) && Self.frameMatches($0.bounds, state.frame) }) {
                    matched[state.token] = record
                    taken.insert(record.id)
                }
            }

            var ofThisApp: [Desired] = []
            for state in candidates where state.frame.isValid {
                let record = matched[state.token]
                var flags: LinkWindowFlags = []
                if state.isMinimised { flags.insert(.minimised) }
                if state.isFullScreen { flags.insert(.fullScreen) }
                if state.isMain { flags.insert(.main) }
                if state.isModal { flags.insert(.modal) }
                if record?.isOnScreen == true { flags.insert(.onScreen) }
                let info = LinkWindowInfo(
                    id: WindowID(0), pid: pid, bundleID: bundleID, parentID: nil, kind: .managed,
                    level: Int16(clamping: record?.layer ?? 0), frame: state.frame, scale: system.backingScale(for: state.frame),
                    title: HelperText.bounded(state.title, maxBytes: LinkLimits.maxTitleBytes), flags: flags)
                var desired = Desired(
                    key: .ax(state.token), info: info, zIndex: record.flatMap { zIndexByCG[$0.id] } ?? Int.max)
                desired.isFocusedAX = state.isFocused
                desired.isMainAX = state.isMain
                ofThisApp.append(desired)
            }
            managed.append(contentsOf: ofThisApp)

            let byDepth = ofThisApp.sorted { $0.zIndex < $1.zIndex }
            var transientCount = 0
            for record in records where !taken.contains(record.id) {
                guard transientCount < Self.maxTransientWindowsPerApp else { break }
                guard record.alpha > 0.01, record.isOnScreen, record.bounds.isValid,
                      record.bounds.size.width >= 1, record.bounds.size.height >= 1 else { continue }
                let isPopupLayer = Self.isTransientLayer(record.layer)
                let isSheetLike = record.layer == 0 && byDepth.contains { Self.contains($0.info.frame, record.bounds) }
                guard isPopupLayer || isSheetLike else { continue }
                guard let parent = byDepth.first(where: { Self.intersects($0.info.frame, record.bounds) }) else { continue }
                let info = LinkWindowInfo(
                    id: WindowID(0), pid: pid, bundleID: bundleID, parentID: nil, kind: .transient, level: Int16(clamping: record.layer),
                    frame: record.bounds, scale: system.backingScale(for: record.bounds),
                    title: HelperText.bounded(record.name ?? "", maxBytes: LinkLimits.maxTitleBytes), flags: [.onScreen])
                transient.append(Desired(key: .cg(record.id), info: info, zIndex: zIndexByCG[record.id] ?? Int.max, parentKey: parent.key))
                transientCount += 1
            }
        }

        // Caps: managed windows first, transient ones fill what is left and need their parent to have survived.
        let keptManaged = Array(managed.sorted { $0.zIndex < $1.zIndex }.prefix(LinkLimits.maxWindowsPerSnapshot))
        let keptKeys = Set(keptManaged.map(\.key))
        let room = LinkLimits.maxWindowsPerSnapshot - keptManaged.count
        let keptTransient = Array(transient.filter { $0.parentKey.map(keptKeys.contains) ?? false }.sorted { $0.zIndex < $1.zIndex }.prefix(room))
        let all = (keptManaged + keptTransient).sorted { lhs, rhs in
            lhs.zIndex != rhs.zIndex ? lhs.zIndex < rhs.zIndex : Self.stableLess(lhs.key, rhs.key)
        }

        var activeKey: Key?
        if let frontmost {
            let mine = keptManaged.filter { $0.info.pid == frontmost }
            activeKey = (mine.first { $0.isFocusedAX } ?? mine.first { $0.isMainAX }
                ?? mine.sorted { $0.zIndex < $1.zIndex }.first { !$0.info.flags.contains(.minimised) })?.key
        }
        return (all, activeKey)
    }

    private static func stableLess(_ a: Key, _ b: Key) -> Bool {
        switch (a, b) {
        case (.ax(let x), .ax(let y)): (x.pid, x.id) < (y.pid, y.id)
        case (.cg(let x), .cg(let y)): x < y
        case (.ax, .cg): true
        case (.cg, .ax): false
        }
    }

    private func newID() -> WindowID {
        let id = WindowID(nextID)
        nextID &+= 1
        return id
    }

    private func bump() -> UInt64 {
        stateVersion += 1
        return stateVersion
    }

    private func apply(_ desired: [Desired], activeKey: Key?) {
        let desiredByKey = Dictionary(desired.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })

        // Which published windows survive unchanged in identity. Managed ones never change parent; a transient window
        // whose parent changed is replaced, because the wire format cannot re-parent.
        var kept: [Key: Entry] = [:]
        for (key, entry) in entries {
            guard let wanted = desiredByKey[key], wanted.info.pid == entry.info.pid, wanted.info.kind == entry.info.kind,
                  wanted.info.bundleID == entry.info.bundleID else { continue }
            if wanted.info.kind == .transient {
                guard let parentKey = wanted.parentKey, let parent = entries[parentKey], parent.id == entry.info.parentID,
                      desiredByKey[parentKey] != nil else { continue }
            }
            kept[key] = entry
        }

        var pending: [WindowTrackerEvent] = []
        for (key, entry) in entries.sorted(by: { $0.value.id < $1.value.id }) where kept[key] == nil {
            pending.append(.destroyed(entry.id, stateVersion: bump()))
            tokens.removeValue(forKey: entry.id)
        }

        var next: [Key: Entry] = kept
        let creationOrder = desired.filter { kept[$0.key] == nil }.sorted { lhs, rhs in
            lhs.info.kind != rhs.info.kind ? lhs.info.kind == .managed : lhs.zIndex < rhs.zIndex
        }
        var assigned: [Key: WindowID] = [:]
        for wanted in creationOrder { assigned[wanted.key] = newID() }
        for wanted in desired where kept[wanted.key] == nil {
            guard let id = assigned[wanted.key] else { continue }
            var info = wanted.info
            info.id = id
            if let parentKey = wanted.parentKey { info.parentID = assigned[parentKey] ?? kept[parentKey]?.id }
            next[wanted.key] = Entry(id: id, info: info)
            if case .ax(let token) = wanted.key { tokens[id] = token }
        }
        let newActive = activeKey.flatMap { next[$0]?.id }

        // Flags that depend on the active window.
        for wanted in desired {
            guard var entry = next[wanted.key] else { continue }
            var flags = wanted.info.flags
            if wanted.info.kind == .managed, entry.id == newActive { flags.insert(.focused) }
            entry.info.flags = flags
            if let old = kept[wanted.key] {
                entry.info.id = old.id
                entry.info.parentID = old.info.parentID
            }
            // Fresh values from this refresh.
            entry.info.frame = wanted.info.frame
            entry.info.title = wanted.info.title
            entry.info.level = wanted.info.level
            entry.info.scale = wanted.info.scale
            next[wanted.key] = entry
        }

        for wanted in creationOrder {
            if let entry = next[wanted.key] { pending.append(.created(entry.info, stateVersion: bump())) }
        }
        for (key, old) in kept.sorted(by: { $0.value.id < $1.value.id }) {
            guard let new = next[key] else { continue }
            var update = LinkWindowUpdate(id: new.id, stateVersion: 0)
            var changed = false
            if new.info.frame != old.info.frame { update.frame = new.info.frame; changed = true }
            if new.info.title != old.info.title { update.title = new.info.title; changed = true }
            if new.info.flags != old.info.flags { update.flags = new.info.flags; changed = true }
            if new.info.level != old.info.level { update.level = new.info.level; changed = true }
            if new.info.scale != old.info.scale { update.scale = new.info.scale; changed = true }
            if changed {
                update.stateVersion = bump()
                pending.append(.updated(update))
            }
        }

        let newOrder = desired.compactMap { next[$0.key]?.id }
        let orderChanged = newOrder != order || newActive != active
        entries = next
        if orderChanged {
            order = newOrder
            active = newActive
            pending.append(.order(ids: newOrder, active: newActive, stateVersion: bump()))
        }
        for event in pending { emit(event) }
    }
}
#endif
