#if os(macOS)
import Foundation
import LinkProtocol

public struct InstalledAppInfo: Sendable, Hashable {
    public var bundleID: String
    public var name: String
    public var version: String
    public var url: URL
    public init(bundleID: String, name: String, version: String, url: URL) {
        self.bundleID = bundleID; self.name = name; self.version = version; self.url = url
    }
}

public protocol InstalledAppSource: Sendable {
    func installedApps() -> [InstalledAppInfo]
}

/// Scans the application folders. Bounded in depth, count and per-folder entries; the first root wins when a bundle id
/// appears twice (so `/Applications` beats a copy in `~/Applications`).
public struct FileManagerAppScanner: InstalledAppSource {
    public var roots: [URL]
    public var maxApps: Int
    /// Subfolder levels below a root that are searched (`/Applications/Utilities/Terminal.app` is level 1).
    public var maxDepth: Int
    public var maxEntriesPerFolder: Int

    public static var defaultRoots: [URL] {
        [URL(fileURLWithPath: "/Applications"), URL(fileURLWithPath: "/System/Applications"),
         FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
    }

    public init(roots: [URL] = FileManagerAppScanner.defaultRoots, maxApps: Int = LinkLimits.maxApps, maxDepth: Int = 2, maxEntriesPerFolder: Int = 2000) {
        self.roots = roots; self.maxApps = maxApps; self.maxDepth = maxDepth; self.maxEntriesPerFolder = maxEntriesPerFolder
    }

    public func installedApps() -> [InstalledAppInfo] {
        var result: [InstalledAppInfo] = []
        var seen = Set<String>()
        for root in roots {
            scan(root, depth: 0, into: &result, seen: &seen)
            if result.count >= maxApps { break }
        }
        return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func scan(_ folder: URL, depth: Int, into result: inout [InstalledAppInfo], seen: inout Set<String>) {
        guard result.count < maxApps,
              let entries = try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])
        else { return }
        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }).prefix(maxEntriesPerFolder) {
            guard result.count < maxApps else { return }
            let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values?.isDirectory == true else { continue }
            if entry.pathExtension.lowercased() == "app" {
                if let app = Self.read(bundleAt: entry), seen.insert(app.bundleID).inserted { result.append(app) }
            } else if depth < maxDepth, values?.isSymbolicLink != true {
                scan(entry, depth: depth + 1, into: &result, seen: &seen)
            }
        }
    }

    /// `nil` for anything that is not a launchable application bundle.
    static func read(bundleAt url: URL) -> InstalledAppInfo? {
        let plistURL = url.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plistURL, options: .mappedIfSafe), data.count <= 4 << 20,
              let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
              let bundleID = plist["CFBundleIdentifier"] as? String, !bundleID.isEmpty,
              bundleID.utf8.count <= LinkLimits.maxBundleIDBytes
        else { return nil }
        guard (plist["CFBundlePackageType"] as? String) == "APPL" else { return nil }
        if (plist["LSBackgroundOnly"] as? Bool) == true || (plist["LSBackgroundOnly"] as? String) == "1" { return nil }
        let fallbackName = url.deletingPathExtension().lastPathComponent
        let name = (plist["CFBundleDisplayName"] as? String) ?? (plist["CFBundleName"] as? String) ?? fallbackName
        let version = (plist["CFBundleShortVersionString"] as? String) ?? (plist["CFBundleVersion"] as? String) ?? ""
        return InstalledAppInfo(
            bundleID: bundleID, name: HelperText.bounded(name.isEmpty ? fallbackName : name, maxBytes: LinkLimits.maxNameBytes),
            version: HelperText.bounded(version, maxBytes: 64), url: url)
    }
}
#endif
