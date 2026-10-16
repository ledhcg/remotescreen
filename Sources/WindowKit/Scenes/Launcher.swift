import Foundation
import LinkProtocol

/// Which lists of apps the launcher has asked the Mac for. `apps.items` carries no tag, so answers are matched to requests in the
/// order they were sent (the control stream is ordered).
public struct AppsDirectory: Sendable, Equatable {
    public private(set) var running: [LinkAppInfo] = []
    public private(set) var recent: [LinkAppInfo] = []
    public private(set) var installed: [LinkAppInfo] = []
    public private(set) var loaded: Set<UInt8> = []
    private var pending: [LinkAppFilter] = []

    /// More requests than this in flight means the Mac does not answer; further ones are dropped until it does.
    public static let maxPending = 6

    public init() {}

    public func hasLoaded(_ filter: LinkAppFilter) -> Bool { loaded.contains(filter.rawValue) }

    /// Returns whether `apps.list(filter)` should be sent now (not when one for the same filter is already on its way).
    public mutating func willRequest(_ filter: LinkAppFilter) -> Bool {
        guard !pending.contains(filter), pending.count < Self.maxPending else { return false }
        pending.append(filter)
        return true
    }

    /// An `apps.items` message arrived. Returns the filter it answers, or `nil` when none was asked for (it is then ignored).
    @discardableResult
    public mutating func receive(_ items: [LinkAppInfo]) -> LinkAppFilter? {
        guard !pending.isEmpty else { return nil }
        let filter = pending.removeFirst()
        let bounded = Array(Self.unique(items).prefix(LinkLimits.maxApps))
        switch filter {
        case .running: running = bounded
        case .recent: recent = bounded
        case .installed: installed = bounded
        }
        loaded.insert(filter.rawValue)
        return filter
    }

    /// The connection was lost: answers still in flight will never come.
    public mutating func connectionLost() { pending.removeAll() }

    private static func unique(_ items: [LinkAppInfo]) -> [LinkAppInfo] {
        var seen = Set<String>()
        return items.filter { seen.insert($0.bundleID).inserted }
    }
}

public enum LauncherSection: Sendable, Equatable, Hashable {
    case running, recent, installed
    /// Search results: one flat list.
    case results

    public var title: String {
        switch self {
        case .running: tr("Running")
        case .recent: tr("Recent")
        case .installed: tr("All apps")
        case .results: tr("Results")
        }
    }
}

public struct LauncherEntry: Sendable, Equatable, Identifiable {
    public var app: LinkAppInfo
    public var isRunning: Bool
    /// Managed windows of the app right now.
    public var windowCount: Int
    /// New windows the user has not looked at yet (policy "badge").
    public var badge: Int
    public var id: String { app.bundleID }
}

public struct LauncherListing: Sendable, Equatable {
    public var sections: [(section: LauncherSection, entries: [LauncherEntry])]

    public static func == (lhs: LauncherListing, rhs: LauncherListing) -> Bool {
        lhs.sections.count == rhs.sections.count
            && zip(lhs.sections, rhs.sections).allSatisfy { $0.section == $1.section && $0.entries == $1.entries }
    }

    public var isEmpty: Bool { sections.allSatisfy { $0.entries.isEmpty } }

    /// - Parameters:
    ///   - running: apps running on the Mac now (from the workspace). Their window counts come from `workspace`.
    ///   - query: what the user typed; matches name or bundle id ignoring case, diacritics and surrounding space.
    public static func build(
        directory: AppsDirectory, workspace: RemoteWorkspace, badges: [String: Int] = [:], query: String
    ) -> LauncherListing {
        let runningApps = workspace.sortedApps
        let runningIDs = Set(runningApps.map(\.bundleID))
        func entry(_ app: LinkAppInfo) -> LauncherEntry {
            LauncherEntry(
                app: app, isRunning: runningIDs.contains(app.bundleID),
                windowCount: workspace.managedWindows(bundleID: app.bundleID).count, badge: badges[app.bundleID] ?? 0)
        }
        let needle = fold(query)
        func matches(_ app: LinkAppInfo) -> Bool {
            needle.isEmpty || fold(app.name).contains(needle) || fold(app.bundleID).contains(needle)
        }
        if !needle.isEmpty {
            var seen = Set<String>()
            let merged = (runningApps + directory.recent + directory.installed).filter { matches($0) && seen.insert($0.bundleID).inserted }
            return LauncherListing(sections: [(.results, merged.map(entry))])
        }
        let recent = directory.recent.filter { !runningIDs.contains($0.bundleID) }
        return LauncherListing(sections: [
            (.running, runningApps.map(entry)),
            (.recent, recent.map(entry)),
            (.installed, sortedByName(directory.installed).map(entry)),
        ].filter { !$0.1.isEmpty })
    }

    private static func sortedByName(_ apps: [LinkAppInfo]) -> [LinkAppInfo] {
        apps.sorted { a, b in
            let (x, y) = (a.name.lowercased(), b.name.lowercased())
            return x != y ? x < y : a.bundleID < b.bundleID
        }
    }

    private static func fold(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}

/// How a window is shown when the user opens an app from the launcher.
public enum AppOpenStyle: String, Sendable, CaseIterable {
    /// One iPad window per Mac window.
    case separateWindows
    /// One iPad window for the app, with a tab bar to switch between the app's Mac windows.
    case tabs
}

/// What tapping an app in the launcher does.
public struct AppOpenPlan: Sendable, Equatable {
    public enum Start: Sendable, Equatable {
        /// The app is not running: launch it and open its first window when it appears.
        case launch
        /// The app is running without a window to show: activate it (it may create one) and open the first that appears.
        case activateAndWait
        /// Windows are there to show.
        case showWindows
    }

    public var start: Start
    /// Windows that need a new scene.
    public var windowsToOpen: [WindowID]
    /// Windows that already have a scene: bring those forward instead of opening another.
    public var windowsToFocus: [WindowID]

    public static func make(
        bundleID: String, workspace: RemoteWorkspace, bindings: SceneBindings, style: AppOpenStyle, canOpenSeveralScenes: Bool
    ) -> AppOpenPlan {
        let windows = workspace.managedWindows(bundleID: bundleID).sorted { $0.id < $1.id }.map(\.id)
        guard !windows.isEmpty else {
            return AppOpenPlan(start: workspace.app(bundleID: bundleID) == nil ? .launch : .activateAndWait, windowsToOpen: [], windowsToFocus: [])
        }
        let open = windows.filter { bindings.scene(for: $0) == nil }
        let focus = windows.filter { bindings.scene(for: $0) != nil }
        // One scene only (tabs, or a device that has a single scene): show the first window that is not shown yet, else focus the app's.
        if style == .tabs || !canOpenSeveralScenes {
            if focus.isEmpty, let first = open.first { return AppOpenPlan(start: .showWindows, windowsToOpen: [first], windowsToFocus: []) }
            return AppOpenPlan(start: .showWindows, windowsToOpen: [], windowsToFocus: Array(focus.prefix(1)))
        }
        return AppOpenPlan(start: .showWindows, windowsToOpen: open, windowsToFocus: focus)
    }
}

/// What to do with a Mac window that appeared after the session started.
public enum NewWindowPolicy: String, Sendable, CaseIterable {
    /// Open an iPad scene for it.
    case autoOpen
    /// Only show a badge on the app in the launcher.
    case badge
}

/// Notices new Mac windows between workspace updates, decides whether to open a scene for each or only badge the app, and forgets
/// them when they go away or get a scene.
public struct NewWindowInbox: Sendable, Equatable {
    private var known: Set<WindowID>?
    private var unseen: [String: Set<WindowID>] = [:]
    public private(set) var toOpen: [WindowID] = []

    public init() {}

    /// New windows per app, for the badge.
    public var badges: [String: Int] { unseen.mapValues(\.count) }

    /// Everything in the workspace now counts as already seen (first snapshot, and a snapshot after a reconnect).
    public mutating func rebaseline(_ workspace: RemoteWorkspace) {
        known = Set(workspace.windows.keys)
        unseen = [:]
        toOpen = []
    }

    /// Call after every workspace change.
    /// - Parameters:
    ///   - sceneApps: apps that have a scene open; with `autoOpen` their new windows get a scene too.
    ///   - expecting: apps the user just launched; their first window opens even when the app had no scene yet.
    ///   - bound: windows that already have a scene.
    /// - Returns: the apps whose expectation was fulfilled.
    @discardableResult
    public mutating func update(
        workspace: RemoteWorkspace, policy: NewWindowPolicy, sceneApps: Set<String>, expecting: Set<String>, bound: Set<WindowID>
    ) -> Set<String> {
        guard workspace.hasSnapshot else { return [] }
        guard let known else {
            rebaseline(workspace)
            return []
        }
        var fulfilled = Set<String>()
        for window in workspace.orderedWindows.reversed() where window.isManaged && !known.contains(window.id) {
            self.known?.insert(window.id)
            if expecting.contains(window.bundleID), !fulfilled.contains(window.bundleID) {
                fulfilled.insert(window.bundleID)
                toOpen.append(window.id)
            } else if policy == .autoOpen, sceneApps.contains(window.bundleID) {
                toOpen.append(window.id)
            } else {
                unseen[window.bundleID, default: []].insert(window.id)
            }
        }
        // Gone or shown windows stop counting.
        for (bundle, windows) in unseen {
            let still = windows.filter { workspace.window($0)?.isManaged == true && !bound.contains($0) }
            unseen[bundle] = still.isEmpty ? nil : still
        }
        toOpen = toOpen.filter { workspace.window($0)?.isManaged == true && !bound.contains($0) }
        // Windows that went away are forgotten, so the set stays as small as the workspace.
        self.known = Set(workspace.windows.keys)
        return fulfilled
    }

    public mutating func takeToOpen() -> [WindowID] {
        defer { toOpen = [] }
        return toOpen
    }

    public mutating func clearBadge(bundleID: String) { unseen[bundleID] = nil }
}

/// A line of the window switcher (the tab bar, and the sheet on iPhone).
public struct WindowSwitcherItem: Sendable, Equatable, Identifiable {
    public var id: WindowID
    public var title: String
    public var appName: String
    public var bundleID: String
    public var isCurrent: Bool
    /// Shown by another scene (iPad only); choosing it focuses that scene instead of rebinding this one.
    public var isShownElsewhere: Bool
}

public enum WindowSwitcher {
    /// Managed windows grouped by app. `onlyApp` limits the list to one app (the tab bar); `nil` lists every app (the iPhone sheet).
    public static func items(
        workspace: RemoteWorkspace, current: WindowID?, bindings: SceneBindings, thisScene: SceneID?, onlyApp: String? = nil
    ) -> [WindowSwitcherItem] {
        workspace.windowsForLauncher.filter { onlyApp == nil || $0.bundleID == onlyApp }.map { window in
            let shownBy = bindings.scene(for: window.id)
            return WindowSwitcherItem(
                id: window.id, title: window.title, appName: workspace.app(bundleID: window.bundleID)?.name ?? window.bundleID,
                bundleID: window.bundleID, isCurrent: window.id == current, isShownElsewhere: shownBy != nil && shownBy != thisScene)
        }
    }
}
