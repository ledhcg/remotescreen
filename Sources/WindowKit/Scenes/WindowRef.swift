import Foundation
import LinkProtocol

/// What an iPad scene stores to show a Mac window: the live window id plus a hint to find the window again.
///
/// The live id is only good for this helper run (it restarts from 1 when the helper restarts), so the hint (app, title, position
/// among the app's windows) is what survives a relaunch of the iPad app or a restart of the helper. Encoded as a string because
/// the scene role carries the reference as an opaque `String`; the plain number the first versions used still decodes.
public struct WindowRef: Sendable, Equatable, Hashable {
    public var windowID: WindowID?
    public var query: WindowMatchQuery?

    public init(windowID: WindowID?, query: WindowMatchQuery?) {
        self.windowID = windowID
        self.query = query
    }

    /// The reference of a live window, with the hint taken from the workspace. `nil` when the window is not a managed window.
    public init?(window id: WindowID, in workspace: RemoteWorkspace) {
        guard let query = workspace.matchQuery(for: id) else { return nil }
        self.init(windowID: id, query: query)
    }

    /// Longest encoded reference accepted; a title is not kept beyond `maxTitleLength` characters.
    public static let maxEncodedLength = 2048
    public static let maxTitleLength = 256

    private struct Wire: Codable {
        var w: UInt32?
        var b: String?
        var t: String?
        var i: Int?
    }

    /// Text for `SceneRole.remoteWindow(windowRef:)`. Plain digits when there is no hint, otherwise JSON.
    public var encoded: String {
        guard let query else { return windowID.map { String($0.rawValue) } ?? "" }
        let wire = Wire(w: windowID?.rawValue, b: query.bundleID, t: String(query.title.prefix(Self.maxTitleLength)), i: query.indexHint)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(wire), let text = String(data: data, encoding: .utf8),
              text.utf8.count <= Self.maxEncodedLength else {
            return windowID.map { String($0.rawValue) } ?? ""
        }
        return text
    }

    /// Parses `encoded`, or a plain window number. `nil` for anything else (a reference from outside is just text to be doubted).
    public init?(encoded text: String) {
        guard text.utf8.count <= Self.maxEncodedLength else { return nil }
        if let number = UInt32(text) {
            self.init(windowID: WindowID(rawValue: number), query: nil)
            return
        }
        guard let data = text.data(using: .utf8), let wire = try? JSONDecoder().decode(Wire.self, from: data) else { return nil }
        var query: WindowMatchQuery?
        if let bundle = wire.b {
            guard let index = wire.i, index >= 0, index < 10_000, bundle.utf8.count <= 512 else { return nil }
            query = WindowMatchQuery(bundleID: bundle, title: wire.t ?? "", indexHint: index)
        }
        guard wire.w != nil || query != nil else { return nil }
        self.init(windowID: wire.w.map { WindowID(rawValue: $0) }, query: query)
    }

    /// The key that identifies "this window" across scenes: live id when known, otherwise the hint. Used to focus an existing scene
    /// instead of opening a second one.
    public var identity: String {
        if let windowID { return "w\(windowID.rawValue)" }
        if let query { return "q\(query.bundleID)|\(query.title)|\(query.indexHint)" }
        return ""
    }
}

extension WindowRef {
    /// How a scene should start showing its window.
    public enum Start: Sendable, Equatable {
        /// Bind to this live window right away.
        case bind(WindowID)
        /// Look for the window with this hint (once a snapshot exists).
        case search(WindowMatchQuery)
        /// Nothing to go on: show the placeholder.
        case nothing
    }

    /// Decides between the stored live id and the hint. A stale id can point to another window after a helper restart, so it is trusted
    /// only when the window it names still fits the hint at least as well as the best match found by the hint.
    public func start(in workspace: RemoteWorkspace, excluding: Set<WindowID> = []) -> Start {
        guard let query else {
            guard let windowID else { return .nothing }
            return .bind(windowID)
        }
        guard workspace.hasSnapshot else { return .search(query) }
        let best = workspace.bestMatch(for: query, excluding: excluding)
        if let windowID, !excluding.contains(windowID), let live = workspace.window(windowID), live.isManaged, live.bundleID == query.bundleID {
            let liveIndex = workspace.matchQuery(for: windowID)?.indexHint ?? 0
            let liveScore = WindowMatchScoring.score(query, title: live.title, index: liveIndex)
            if liveScore >= WindowMatchScoring.minimumAcceptable, liveScore >= (best?.score ?? 0) { return .bind(windowID) }
        }
        if let best { return .bind(best.id) }
        return .search(query)
    }
}
