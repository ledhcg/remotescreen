#if os(macOS)
import Foundation
import LinkProtocol
import os

/// A frame in global points, in a form that can be written to JSON.
public struct StageFrame: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public init(_ rect: LinkRect) { x = rect.origin.x; y = rect.origin.y; width = rect.size.width; height = rect.size.height }
    public var rect: LinkRect { LinkRect(x: x, y: y, width: width, height: height) }
}

/// What the stage promised to put back: every window it moved or resized, with where it was.
/// Contains no titles, names or paths: only process ids, window numbers and rectangles.
public struct StageJournal: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var window: StageWindowKey
        public var frame: StageFrame
        public var display: StageDisplayID?
        public init(window: StageWindowKey, frame: StageFrame, display: StageDisplayID?) {
            self.window = window; self.frame = frame; self.display = display
        }
    }

    public static let currentVersion = 1
    public static let maxEntries = 1024

    public var version: Int
    /// Identifies this boot of the Mac. Window numbers do not survive a reboot, so a journal from another boot is stale.
    public var bootID: String
    public var entries: [Entry]

    public init(bootID: String, entries: [Entry] = []) {
        version = Self.currentVersion; self.bootID = bootID; self.entries = entries
    }
}

/// Where the journal lives. Saves must be atomic: after `save` returns, a crash leaves the new content or the old one, never half.
public protocol StageJournalStore: Sendable {
    func load() async throws -> StageJournal?
    func save(_ journal: StageJournal) async throws
    func clear() async throws
}

public enum StageJournalError: Error, Equatable {
    case corrupt
    case tooLarge
}

/// `Application Support/Screon Helper/stage-journal.json`, written atomically with owner-only permissions.
public struct FileStageJournalStore: StageJournalStore {
    public let url: URL
    static let maxFileBytes = 1 << 20

    public init(url: URL) { self.url = url }

    public static func defaultURL() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return base.appending(path: "Screon Helper", directoryHint: .isDirectory).appending(path: "stage-journal.json", directoryHint: .notDirectory)
    }

    public func load() async throws -> StageJournal? {
        let data: Data
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            if let size = attributes[.size] as? Int, size > Self.maxFileBytes { throw StageJournalError.tooLarge }
            data = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return nil
        } catch let error as StageJournalError {
            throw error
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            return nil
        }
        guard let journal = try? JSONDecoder().decode(StageJournal.self, from: data),
              journal.version == StageJournal.currentVersion,
              journal.entries.count <= StageJournal.maxEntries,
              journal.entries.allSatisfy({ $0.frame.rect.isValid }) else { throw StageJournalError.corrupt }
        return journal
    }

    public func save(_ journal: StageJournal) async throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(journal)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public func clear() async throws {
        do { try FileManager.default.removeItem(at: url) } catch let error as CocoaError where error.code == .fileNoSuchFile {}
    }
}

/// `kern.boottime` as a string: changes on every reboot.
public func currentBootIdentifier() -> String {
    var value = timeval()
    var size = MemoryLayout<timeval>.size
    guard sysctlbyname("kern.boottime", &value, &size, nil, 0) == 0 else { return "unknown" }
    return "\(value.tv_sec)"
}
#endif
