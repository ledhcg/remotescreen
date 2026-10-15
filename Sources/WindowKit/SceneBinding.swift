import Foundation
import LinkProtocol

/// Identity of an iPad scene (the persistent identifier of its `UISceneSession`).
public struct SceneID: Hashable, Sendable, Codable, Comparable {
    public var rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public static func < (lhs: SceneID, rhs: SceneID) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// What a scene shows.
public enum SceneBindingState: Sendable, Equatable {
    /// Showing this window.
    case bound(WindowID)
    /// Restoring: waiting for the helper's snapshot before the window can be found.
    case restoring(WindowMatchQuery)
    /// The window is gone. The scene keeps a placeholder and `reopenHint` to find a successor.
    case windowClosed(reopenHint: WindowMatchQuery)

    public var windowID: WindowID? {
        if case .bound(let id) = self { return id }
        return nil
    }

    /// Text for the placeholder shown instead of the window, or `nil` while a window is bound.
    public var placeholderMessage: String? {
        switch self {
        case .bound: nil
        case .restoring: tr("Looking for this window on the Mac…")
        case .windowClosed: tr("This window was closed on the Mac.")
        }
    }

    /// Secondary line suggesting what to do next, or `nil` when there is nothing to suggest.
    public var placeholderHint: String? {
        if case .windowClosed = self { return tr("Choose another window from the launcher.") }
        return nil
    }
}

public enum OpenWindowResult: Sendable, Equatable {
    /// The window was not open: the scene is now bound to it.
    case bound
    /// The window is already shown by this scene: focus it instead of opening another.
    case focusExisting(SceneID)
}

/// Maps windows to scenes, one scene per window, and keeps scenes valid as the Mac's windows come and go.
public struct SceneBindings: Sendable, Equatable {
    private struct Entry: Equatable {
        var state: SceneBindingState
        /// Last known query for the bound window, kept up to date, so closing the window leaves a usable hint.
        var query: WindowMatchQuery?
    }

    private var entries: [SceneID: Entry] = [:]

    public init() {}

    public var scenes: [SceneID] { entries.keys.sorted() }

    public func state(of scene: SceneID) -> SceneBindingState? { entries[scene]?.state }

    /// The scene showing `window`, if any.
    public func scene(for window: WindowID) -> SceneID? {
        entries.filter { $0.value.state.windowID == window }.keys.min()
    }

    /// Opens `window` in `scene`. A window that is already shown by another scene is never bound twice: the existing scene is
    /// returned to focus. Rebinding a scene to a different window replaces its previous binding.
    @discardableResult
    public mutating func open(window: WindowID, in scene: SceneID, workspace: RemoteWorkspace) -> OpenWindowResult {
        if let existing = self.scene(for: window), existing != scene { return .focusExisting(existing) }
        entries[scene] = Entry(state: .bound(window), query: workspace.matchQuery(for: window))
        return .bound
    }

    /// Restores a scene from its saved query. Returns the new state: bound to the best live window not shown by another scene,
    /// `restoring` while there is no snapshot yet, or `windowClosed` when nothing matches.
    @discardableResult
    public mutating func restore(scene: SceneID, query: WindowMatchQuery, workspace: RemoteWorkspace) -> SceneBindingState {
        let state = resolve(query, workspace: workspace, excluding: boundWindows(except: scene))
        entries[scene] = Entry(state: state, query: query)
        if case .bound(let id) = state { entries[scene]?.query = workspace.matchQuery(for: id) ?? query }
        return state
    }

    /// Looks again for a window for a closed scene, for example after the user reopened the document. Returns whether it bound.
    @discardableResult
    public mutating func rebind(scene: SceneID, workspace: RemoteWorkspace) -> Bool {
        guard case .windowClosed(let hint)? = entries[scene]?.state else { return false }
        guard let match = workspace.bestMatch(for: hint, excluding: boundWindows(except: scene)) else { return false }
        entries[scene] = Entry(state: .bound(match.id), query: workspace.matchQuery(for: match.id) ?? hint)
        return true
    }

    /// Call after every workspace change. Windows that disappeared turn their scene into `.windowClosed`; scenes still `.restoring`
    /// retry once a snapshot exists; titles and indexes of bound windows are refreshed. Returns the scenes whose state changed.
    @discardableResult
    public mutating func reconcile(with workspace: RemoteWorkspace) -> [SceneID] {
        var changed: [SceneID] = []
        for scene in scenes {
            guard let entry = entries[scene] else { continue }
            switch entry.state {
            case .bound(let id):
                if workspace.hasSnapshot, workspace.window(id)?.isManaged != true {
                    let hint = entry.query ?? WindowMatchQuery(bundleID: "", title: "", indexHint: 0)
                    entries[scene] = Entry(state: .windowClosed(reopenHint: hint), query: hint)
                    changed.append(scene)
                } else if let query = workspace.matchQuery(for: id) {
                    entries[scene]?.query = query
                }
            case .restoring(let query):
                guard workspace.hasSnapshot else { continue }
                let state = resolve(query, workspace: workspace, excluding: boundWindows(except: scene))
                entries[scene] = Entry(state: state, query: state.windowID.flatMap { workspace.matchQuery(for: $0) } ?? query)
                changed.append(scene)
            case .windowClosed:
                continue
            }
        }
        return changed
    }

    /// The scene was destroyed by the user.
    public mutating func remove(scene: SceneID) { entries[scene] = nil }

    /// The saved query of a scene, to put in its state restoration activity.
    public func restorationQuery(for scene: SceneID) -> WindowMatchQuery? {
        guard let entry = entries[scene] else { return nil }
        switch entry.state {
        case .bound: return entry.query
        case .restoring(let query): return query
        case .windowClosed(let hint): return hint
        }
    }

    // MARK: Helpers

    private func boundWindows(except scene: SceneID) -> Set<WindowID> {
        Set(entries.compactMap { $0.key == scene ? nil : $0.value.state.windowID })
    }

    private func resolve(_ query: WindowMatchQuery, workspace: RemoteWorkspace, excluding: Set<WindowID>) -> SceneBindingState {
        guard workspace.hasSnapshot else { return .restoring(query) }
        if let match = workspace.bestMatch(for: query, excluding: excluding) { return .bound(match.id) }
        return .windowClosed(reopenHint: query)
    }
}
