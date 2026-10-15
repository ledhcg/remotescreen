#if os(macOS)
import Foundation
import LinkProtocol

/// The last apps launched through the helper, newest first. Only bundle ids are stored: no document titles or paths.
public struct RecentApps: Sendable, Equatable {
    public private(set) var bundleIDs: [String]
    public let limit: Int

    public init(bundleIDs: [String] = [], limit: Int = 12) {
        self.limit = max(1, limit)
        self.bundleIDs = Array(bundleIDs.filter { Self.isValid($0) }.prefix(self.limit))
    }

    static func isValid(_ id: String) -> Bool { !id.isEmpty && id.utf8.count <= LinkLimits.maxBundleIDBytes }

    public mutating func record(_ bundleID: String) {
        guard Self.isValid(bundleID) else { return }
        bundleIDs.removeAll { $0 == bundleID }
        bundleIDs.insert(bundleID, at: 0)
        if bundleIDs.count > limit { bundleIDs.removeLast(bundleIDs.count - limit) }
    }

    private struct Stored: Codable { var version: Int; var bundleIDs: [String] }

    /// Empty when the file is missing, unreadable or corrupt.
    public static func load(from url: URL, limit: Int = 12) -> RecentApps {
        guard let data = try? Data(contentsOf: url), data.count <= 1 << 20,
              let stored = try? JSONDecoder().decode(Stored.self, from: data), stored.version == 1
        else { return RecentApps(limit: limit) }
        return RecentApps(bundleIDs: stored.bundleIDs, limit: limit)
    }

    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(Stored(version: 1, bundleIDs: bundleIDs))
        try data.write(to: url, options: .atomic)
    }

    /// `~/Library/Application Support/Screon/recent-apps.json`.
    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Screon", isDirectory: true).appendingPathComponent("recent-apps.json")
    }
}
#endif
