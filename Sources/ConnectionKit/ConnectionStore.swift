import Foundation

/// Persists a `ConnectionList` as a JSON file.
public struct ConnectionStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// Default location in the app's Application Support.
    public static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("connections.json")
    }

    /// Reads the list. Returns an empty list if there is no file yet.
    ///
    /// A corrupt file is **not deleted**: it is renamed to `connections.corrupt-<timestamp>.json` and an empty list is returned,
    /// so the user does not lose data because of one interrupted write or an older app version.
    public func load() -> ConnectionList {
        guard let data = try? Data(contentsOf: fileURL) else { return ConnectionList() }
        do {
            return try JSONDecoder().decode(ConnectionList.self, from: data)
        } catch {
            let stamp = Int(Date().timeIntervalSince1970)
            let backup = fileURL.deletingLastPathComponent()
                .appendingPathComponent("\(fileURL.deletingPathExtension().lastPathComponent).corrupt-\(stamp).json")
            try? FileManager.default.moveItem(at: fileURL, to: backup)
            return ConnectionList()
        }
    }

    /// Atomic write: either the complete new file or the intact old one, never half of each.
    public func save(_ list: ConnectionList) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(list).write(to: fileURL, options: .atomic)
    }
}
