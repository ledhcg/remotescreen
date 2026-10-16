import Foundation
import LinkProtocol

/// Name of one cached app icon on disk: the helper's icon key and the pixel size that was asked for.
public struct IconCacheKey: Hashable, Sendable {
    public var iconKey: IconKey
    public var pixelSize: UInt16

    public init(iconKey: IconKey, pixelSize: UInt16) {
        self.iconKey = iconKey
        self.pixelSize = pixelSize
    }

    /// `icon-<key>-<size>.png`. Built only from numbers, so a hostile peer cannot influence the path.
    public var fileName: String { "icon-\(iconKey.rawValue)-\(pixelSize).png" }

    /// Parses a file name written by `fileName`; `nil` for anything else (such files are not ours and are left alone).
    public init?(fileName: String) {
        guard fileName.hasPrefix("icon-"), fileName.hasSuffix(".png") else { return nil }
        let body = fileName.dropFirst(5).dropLast(4)
        let parts = body.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2, let key = UInt32(parts[0]), let size = UInt16(parts[1]) else { return nil }
        self.init(iconKey: IconKey(rawValue: key), pixelSize: size)
        guard self.fileName == fileName else { return nil }
    }
}

/// Which pixel size to ask the Mac for. Few distinct sizes, so the cache holds one picture per app and a size changes rarely.
public enum IconSize {
    public static let buckets: [UInt16] = [64, 128, 256]

    /// The smallest bucket that covers `points` at `scale`.
    public static func pixels(points: Double, scale: Double) -> UInt16 {
        let wanted = points.isFinite && scale.isFinite ? points * max(scale, 1) : 0
        return buckets.first { Double($0) >= wanted } ?? buckets[buckets.count - 1]
    }
}

/// Bookkeeping for the on-disk icon cache: which files exist, how big they are, and which to delete first (least recently used).
/// The index does no I/O; the app deletes the files it returns. Bounded in bytes and in file count, so a Mac that lists thousands of
/// apps cannot fill the iPad.
public struct IconCacheIndex: Sendable, Equatable {
    public struct Limits: Sendable, Equatable {
        public var maxTotalBytes: Int
        public var maxEntries: Int
        /// A single icon larger than this is not cached at all.
        public var maxEntryBytes: Int
        public init(maxTotalBytes: Int = 8 * 1024 * 1024, maxEntries: Int = 400, maxEntryBytes: Int = 512 * 1024) {
            self.maxTotalBytes = maxTotalBytes
            self.maxEntries = maxEntries
            self.maxEntryBytes = maxEntryBytes
        }
    }

    private struct Entry: Equatable {
        var bytes: Int
        var tick: UInt64
    }

    public let limits: Limits
    private var entries: [IconCacheKey: Entry] = [:]
    private var clock: UInt64 = 0
    public private(set) var totalBytes = 0

    public init(limits: Limits = Limits()) { self.limits = limits }

    public var count: Int { entries.count }

    public func contains(_ key: IconCacheKey) -> Bool { entries[key] != nil }

    /// Rebuilds the index from the files found on disk, oldest first (by modification time). Returns the files to delete because
    /// the cache is over its limits.
    public mutating func rebuild(from files: [(key: IconCacheKey, bytes: Int, modified: Date)]) -> [IconCacheKey] {
        self = IconCacheIndex(limits: limits)
        var evicted: [IconCacheKey] = []
        for file in files.sorted(by: { $0.modified != $1.modified ? $0.modified < $1.modified : $0.key.fileName < $1.key.fileName }) {
            if file.bytes <= 0 || file.bytes > limits.maxEntryBytes {
                evicted.append(file.key)
                continue
            }
            clock += 1
            entries[file.key] = Entry(bytes: file.bytes, tick: clock)
            totalBytes += file.bytes
        }
        evicted += evictOverLimit(keeping: nil)
        return evicted
    }

    /// The icon was used: it becomes the most recently used. Returns false when it is not cached.
    @discardableResult
    public mutating func touch(_ key: IconCacheKey) -> Bool {
        guard entries[key] != nil else { return false }
        clock += 1
        entries[key]?.tick = clock
        return true
    }

    public struct InsertResult: Equatable, Sendable {
        /// False when the icon is too big (or empty) and should not be written.
        public var accepted: Bool
        /// Files to delete to stay within the limits (never the one just inserted).
        public var evicted: [IconCacheKey]
    }

    /// A file of `bytes` was written for `key` (replacing an earlier one).
    public mutating func insert(_ key: IconCacheKey, bytes: Int) -> InsertResult {
        guard bytes > 0, bytes <= limits.maxEntryBytes, bytes <= limits.maxTotalBytes else {
            return InsertResult(accepted: false, evicted: [])
        }
        if let old = entries[key] { totalBytes -= old.bytes }
        clock += 1
        entries[key] = Entry(bytes: bytes, tick: clock)
        totalBytes += bytes
        return InsertResult(accepted: true, evicted: evictOverLimit(keeping: key))
    }

    public mutating func remove(_ key: IconCacheKey) {
        if let old = entries.removeValue(forKey: key) { totalBytes -= old.bytes }
    }

    private mutating func evictOverLimit(keeping keep: IconCacheKey?) -> [IconCacheKey] {
        var evicted: [IconCacheKey] = []
        while totalBytes > limits.maxTotalBytes || entries.count > limits.maxEntries {
            guard let oldest = entries.filter({ $0.key != keep }).min(by: { $0.value.tick < $1.value.tick }) else { break }
            totalBytes -= oldest.value.bytes
            entries[oldest.key] = nil
            evicted.append(oldest.key)
        }
        return evicted
    }
}
