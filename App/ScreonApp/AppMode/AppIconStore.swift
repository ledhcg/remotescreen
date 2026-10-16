import Foundation
import ImageIO
import LinkProtocol
import Observation
import UIKit
import WindowKit

/// App icons of one Mac: asked for with `apps.icon`, kept in memory and on disk in `Caches/` (the system may delete them any time;
/// they are asked for again), least recently used files removed first (`IconCacheIndex`).
///
/// Icon pictures come from the Mac, so they are checked before use: only icons that were asked for are taken, the data is bounded, and
/// the decoder is given a pixel limit (ImageIO thumbnail), so a hostile picture cannot allocate a huge bitmap.
///
/// The file name uses a number made from the bundle id, not the helper's icon key: the helper may number its icons differently after a
/// restart, and the bundle id is what names the app.
@available(iOS 26, *)
@MainActor
@Observable
final class AppIconStore {
    /// Bumped when a new picture arrives, so views that asked for one update.
    private(set) var revision = 0

    @ObservationIgnored private let directory: URL
    @ObservationIgnored private let send: @MainActor (LinkMessage) -> Void
    @ObservationIgnored private var index: IconCacheIndex
    @ObservationIgnored private let memory = NSCache<NSString, UIImage>()
    /// Icons asked for and not yet delivered: helper key → what to store them as.
    @ObservationIgnored private var waiting: [IconKey: IconCacheKey] = [:]
    @ObservationIgnored private var failed: Set<IconCacheKey> = []

    static let maxWaiting = 64
    static let maxDimension = 1024

    init(computerID: UUID, root: URL? = nil, limits: IconCacheIndex.Limits = .init(), send: @escaping @MainActor (LinkMessage) -> Void) {
        let base = root ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        directory = base.appendingPathComponent("AppIcons", isDirectory: true).appendingPathComponent(computerID.uuidString, isDirectory: true)
        self.send = send
        index = IconCacheIndex(limits: limits)
        memory.countLimit = 128
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        rebuildIndex()
    }

    /// The picture for `app`, or `nil` while it is still on its way (the view reads `revision` and asks again when it changes).
    func image(for app: LinkAppInfo, points: Double, scale: Double) -> UIImage? {
        _ = revision  // views that call this refresh when a picture arrives
        let size = IconSize.pixels(points: points, scale: scale)
        let key = IconCacheKey(iconKey: Self.stableKey(bundleID: app.bundleID), pixelSize: size)
        if let image = memory.object(forKey: key.fileName as NSString) {
            index.touch(key)
            return image
        }
        if index.contains(key), let image = loadFromDisk(key) {
            memory.setObject(image, forKey: key.fileName as NSString)
            index.touch(key)
            touchFile(key)
            return image
        }
        request(app.iconKey, as: key)
        return nil
    }

    /// `apps.icon.data` arrived.
    func receive(key helperKey: IconKey, png: Data) {
        guard let cacheKey = waiting.removeValue(forKey: helperKey) else { return }  // nobody asked for it
        guard png.count <= index.limits.maxEntryBytes, let image = Self.decode(png) else {
            failed.insert(cacheKey)
            return
        }
        let result = index.insert(cacheKey, bytes: png.count)
        if result.accepted { try? png.write(to: fileURL(cacheKey), options: .atomic) }
        for old in result.evicted {
            memory.removeObject(forKey: old.fileName as NSString)
            try? FileManager.default.removeItem(at: fileURL(old))
        }
        memory.setObject(image, forKey: cacheKey.fileName as NSString)
        revision += 1
    }

    /// The connection is new: requests in flight are lost.
    func connectionLost() { waiting.removeAll() }

    // MARK: Internals

    private func request(_ helperKey: IconKey, as key: IconCacheKey) {
        guard !failed.contains(key), waiting[helperKey] == nil, waiting.count < Self.maxWaiting else { return }
        waiting[helperKey] = key
        send(.appsIcon(key: helperKey, pixelSize: key.pixelSize))
    }

    private func fileURL(_ key: IconCacheKey) -> URL { directory.appendingPathComponent(key.fileName) }

    private func loadFromDisk(_ key: IconCacheKey) -> UIImage? {
        guard let data = try? Data(contentsOf: fileURL(key)), let image = Self.decode(data) else {
            index.remove(key)
            try? FileManager.default.removeItem(at: fileURL(key))
            return nil
        }
        return image
    }

    /// Reading modification dates is why the privacy manifest declares file timestamp access (reason C617.1: files inside the app's
    /// own container).
    private func rebuildIndex() {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])) ?? []
        var files: [(key: IconCacheKey, bytes: Int, modified: Date)] = []
        for url in urls {
            guard let key = IconCacheKey(fileName: url.lastPathComponent) else { continue }
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            files.append((key, values?.fileSize ?? 0, values?.contentModificationDate ?? .distantPast))
        }
        for old in index.rebuild(from: files) { try? FileManager.default.removeItem(at: fileURL(old)) }
    }

    /// Makes the file the newest, so the order survives a relaunch.
    private func touchFile(_ key: IconCacheKey) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: fileURL(key).path)
    }

    /// FNV-1a over the bundle id.
    static func stableKey(bundleID: String) -> IconKey {
        var hash: UInt32 = 2_166_136_261
        for byte in bundleID.utf8 { hash = (hash ^ UInt32(byte)) &* 16_777_619 }
        return IconKey(rawValue: hash)
    }

    /// Decodes a picture of a stranger with a bound on its size.
    static func decode(_ data: Data) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) >= 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= maxDimension, height <= maxDimension else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 512,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }
}
