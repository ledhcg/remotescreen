import Foundation
import LinkProtocol

/// What a scene remembers about its window, to find it again after a reconnect or relaunch (plan W4).
/// Window ids do not survive a helper restart, so the scene stores the app, the title and the position among the app's windows.
public struct WindowMatchQuery: Sendable, Hashable, Codable {
    public var bundleID: String
    public var title: String
    /// Position of the window among the app's managed windows ordered by window id (creation order) when it was last seen.
    public var indexHint: Int

    public init(bundleID: String, title: String, indexHint: Int) {
        self.bundleID = bundleID
        self.title = title
        self.indexHint = indexHint
    }
}

public struct WindowMatch: Sendable, Equatable {
    public var id: WindowID
    public var score: Int
}

/// Scoring used to re-bind a scene to a live window. The bundle id must be equal; then title and index add up.
///
/// | signal | points |
/// |---|---|
/// | title equal | 100 |
/// | title equal ignoring case, diacritics and surrounding space | 80 |
/// | one title contains the other | 40 |
/// | both titles empty | 30 |
/// | same index | 25 |
/// | index off by `d` | `max(0, 12 - 4d)` |
///
/// A match is acceptable from `minimumAcceptable` points: a window of the right app at the same position, or with a related title.
public enum WindowMatchScoring {
    public static let minimumAcceptable = 25

    public static func score(_ query: WindowMatchQuery, title: String, index: Int) -> Int {
        titleScore(query.title, title) + indexScore(query.indexHint, index)
    }

    static func titleScore(_ wanted: String, _ actual: String) -> Int {
        if wanted == actual { return wanted.isEmpty ? 30 : 100 }
        let a = fold(wanted), b = fold(actual)
        if a.isEmpty && b.isEmpty { return 30 }
        if a.isEmpty || b.isEmpty { return 0 }
        if a == b { return 80 }
        if a.contains(b) || b.contains(a) { return 40 }
        return 0
    }

    static func indexScore(_ wanted: Int, _ actual: Int) -> Int {
        let distance = abs(wanted - actual)
        return distance == 0 ? 25 : max(0, 12 - 4 * min(distance, 100))
    }

    private static func fold(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}

extension RemoteWorkspace {
    /// The query that would find `id` again later, or `nil` when it is not a managed window.
    public func matchQuery(for id: WindowID) -> WindowMatchQuery? {
        guard let window = windows[id], window.isManaged else { return nil }
        let index = stableManagedWindows(bundleID: window.bundleID).firstIndex { $0.id == id } ?? 0
        return WindowMatchQuery(bundleID: window.bundleID, title: window.title, indexHint: index)
    }

    /// Candidates for `query`, best first (ties go to the lower window id), skipping `excluding`. Includes unacceptable scores
    /// so a caller can show them; use `bestMatch` for the decision.
    public func rankedMatches(for query: WindowMatchQuery, excluding: Set<WindowID> = []) -> [WindowMatch] {
        stableManagedWindows(bundleID: query.bundleID).enumerated().compactMap { index, window in
            guard !excluding.contains(window.id) else { return nil }
            return WindowMatch(id: window.id, score: WindowMatchScoring.score(query, title: window.title, index: index))
        }.sorted { $0.score != $1.score ? $0.score > $1.score : $0.id < $1.id }
    }

    /// The best acceptable live window for `query`, or `nil` when none reaches `WindowMatchScoring.minimumAcceptable`.
    public func bestMatch(for query: WindowMatchQuery, excluding: Set<WindowID> = []) -> WindowMatch? {
        rankedMatches(for: query, excluding: excluding).first { $0.score >= WindowMatchScoring.minimumAcceptable }
    }
}
