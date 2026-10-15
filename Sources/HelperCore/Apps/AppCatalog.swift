#if os(macOS)
import Foundation
import LinkProtocol
import os

/// `apps.changed` before it is turned into a message.
public struct AppChangeEvent: Sendable, Equatable {
    public var change: LinkAppChange
    public var app: LinkAppInfo
    public init(change: LinkAppChange, app: LinkAppInfo) { self.change = change; self.app = app }
}

/// Running, installed and recent apps, their icons, and launch/activate/quit.
///
/// Everything OS-facing comes through `WorkspaceAccess` and `InstalledAppSource`, so the logic runs with fakes.
public actor AppCatalog {
    /// Icon sizes are clamped to this range, then to `LinkLimits.maxIconPixelSize`.
    public static let iconSizeRange = 16...512
    public static let defaultIconSize = 128
    static let maxCachedIcons = 512

    private struct IdentityKey: Hashable { var bundleID: String; var version: String }
    private struct IconCacheKey: Hashable { var identity: IdentityKey; var size: Int }

    private let workspace: any WorkspaceAccess
    private let installedSource: any InstalledAppSource
    private let recentsURL: URL?
    private var recents: RecentApps
    private var installedCache: [InstalledAppInfo]?
    private var nextRef: UInt32 = 1
    private var nextIconKey: UInt32 = 1
    private var refs: [String: AppRef] = [:]
    private var iconKeys: [IdentityKey: IconKey] = [:]
    private var identities: [IconKey: IdentityKey] = [:]
    private var iconCache: [IconCacheKey: Data] = [:]
    private var knownByPID: [Int32: RunningAppInfo] = [:]
    private let log = Logger(subsystem: "app.screon.helper", category: "apps")

    public init(workspace: any WorkspaceAccess, installed: any InstalledAppSource, recentsURL: URL? = nil, recentsLimit: Int = 12) {
        self.workspace = workspace
        self.installedSource = installed
        self.recentsURL = recentsURL
        self.recents = recentsURL.map { RecentApps.load(from: $0, limit: recentsLimit) } ?? RecentApps(limit: recentsLimit)
    }

    // MARK: Listing

    /// Rescans the application folders on the next listing.
    public func refreshInstalled() { installedCache = nil }

    public func recentBundleIDs() -> [String] { recents.bundleIDs }

    /// `windowCounts` maps pid to the number of managed windows (the tracker owns that number).
    public func apps(filter: LinkAppFilter, windowCounts: [Int32: Int] = [:]) -> [LinkAppInfo] {
        let running = runningRegularApps()
        let runningByBundle = Dictionary(running.compactMap { app in app.bundleID.map { ($0, app) } }, uniquingKeysWith: { first, _ in first })
        var result: [LinkAppInfo] = []
        switch filter {
        case .running:
            result = running.compactMap { runningInfo($0, windowCounts: windowCounts) }
        case .installed:
            var seen = Set<String>()
            for app in installed() where seen.insert(app.bundleID).inserted {
                result.append(info(for: app, running: runningByBundle[app.bundleID], windowCounts: windowCounts))
            }
            // Running apps outside the scanned folders (for example /opt or a mounted disk image) still belong in the list.
            for app in running {
                guard let id = app.bundleID, seen.insert(id).inserted, let info = runningInfo(app, windowCounts: windowCounts) else { continue }
                result.append(info)
            }
        case .recent:
            let installedByBundle = Dictionary(installed().map { ($0.bundleID, $0) }, uniquingKeysWith: { first, _ in first })
            for id in recents.bundleIDs {
                if let app = installedByBundle[id] {
                    result.append(info(for: app, running: runningByBundle[id], windowCounts: windowCounts))
                } else if let app = runningByBundle[id], let info = runningInfo(app, windowCounts: windowCounts) {
                    result.append(info)
                }
            }
        }
        return Array(result.prefix(LinkLimits.maxApps))
    }

    /// The info of one app by bundle id, if it is installed or running.
    public func app(bundleID: String, windowCounts: [Int32: Int] = [:]) -> LinkAppInfo? {
        if let running = runningRegularApps().first(where: { $0.bundleID == bundleID }) {
            return runningInfo(running, windowCounts: windowCounts)
        }
        return installed().first { $0.bundleID == bundleID }.map { info(for: $0, running: nil, windowCounts: windowCounts) }
    }

    private func installed() -> [InstalledAppInfo] {
        if let installedCache { return installedCache }
        let scanned = installedSource.installedApps()
        installedCache = scanned
        return scanned
    }

    private func runningRegularApps() -> [RunningAppInfo] {
        let apps = workspace.runningApps().filter { $0.isRegular && $0.bundleID != nil && !($0.bundleID ?? "").isEmpty }
        knownByPID = Dictionary(apps.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        return apps
    }

    private func runningInfo(_ app: RunningAppInfo, windowCounts: [Int32: Int]) -> LinkAppInfo? {
        guard let bundleID = app.bundleID, bundleID.utf8.count <= LinkLimits.maxBundleIDBytes else { return nil }
        return LinkAppInfo(
            ref: ref(for: bundleID), bundleID: bundleID, name: HelperText.bounded(app.name, maxBytes: LinkLimits.maxNameBytes), pid: app.pid,
            iconKey: iconKey(bundleID: bundleID, version: app.version ?? ""), isActive: app.isActive,
            windowCount: UInt16(clamping: windowCounts[app.pid] ?? 0))
    }

    private func info(for app: InstalledAppInfo, running: RunningAppInfo?, windowCounts: [Int32: Int]) -> LinkAppInfo {
        LinkAppInfo(
            ref: ref(for: app.bundleID), bundleID: app.bundleID, name: app.name, pid: running?.pid,
            iconKey: iconKey(bundleID: app.bundleID, version: app.version), isActive: running?.isActive ?? false,
            windowCount: UInt16(clamping: running.flatMap { windowCounts[$0.pid] } ?? 0))
    }

    private func ref(for bundleID: String) -> AppRef {
        if let existing = refs[bundleID] { return existing }
        let ref = AppRef(nextRef)
        nextRef &+= 1
        refs[bundleID] = ref
        return ref
    }

    // MARK: Icons

    private func iconKey(bundleID: String, version: String) -> IconKey {
        let identity = IdentityKey(bundleID: bundleID, version: version)
        if let existing = iconKeys[identity] { return existing }
        let key = IconKey(nextIconKey)
        nextIconKey &+= 1
        iconKeys[identity] = key
        identities[key] = identity
        return key
    }

    /// Size actually rendered for a requested size.
    public static func clampedIconSize(_ requested: Int) -> Int {
        min(max(requested, iconSizeRange.lowerBound), min(iconSizeRange.upperBound, Int(LinkLimits.maxIconPixelSize)))
    }

    /// PNG of at most `LinkLimits.maxIconPNGBytes`, rendered at the clamped size (smaller when the PNG would be too big).
    /// `nil` for an unknown key or an icon that cannot be rendered.
    public func iconPNG(key: IconKey, pixelSize: Int = AppCatalog.defaultIconSize) -> Data? {
        guard let identity = identities[key], let url = bundleURL(for: identity) else { return nil }
        var size = Self.clampedIconSize(pixelSize)
        while true {
            let cacheKey = IconCacheKey(identity: identity, size: size)
            if let cached = iconCache[cacheKey] { return cached }
            guard let png = workspace.iconPNG(forBundleAt: url, pixelSize: size) else { return nil }
            if png.count <= LinkLimits.maxIconPNGBytes {
                if iconCache.count >= Self.maxCachedIcons { iconCache.removeAll() }
                iconCache[cacheKey] = png
                return png
            }
            guard size / 2 >= Self.iconSizeRange.lowerBound else { return nil }
            size /= 2
        }
    }

    private func bundleURL(for identity: IdentityKey) -> URL? {
        if let running = knownByPID.values.first(where: { $0.bundleID == identity.bundleID })?.bundleURL { return running }
        if let app = installed().first(where: { $0.bundleID == identity.bundleID }) { return app.url }
        return workspace.bundleURL(forBundleID: identity.bundleID)
    }

    // MARK: Actions

    /// Launches or activates the app and records it in the recents.
    public func launch(bundleID: String) async throws {
        guard RecentApps.isValid(bundleID) else { throw AppLaunchError.notInstalled(bundleID) }
        try await workspace.launch(bundleID: bundleID)
        recents.record(bundleID)
        if let recentsURL {
            do { try recents.save(to: recentsURL) } catch { log.error("Could not save the recent apps: \(String(describing: error), privacy: .public)") }
        }
    }

    @discardableResult
    public func activate(bundleID: String) -> Bool {
        guard let app = runningRegularApps().first(where: { $0.bundleID == bundleID }) else { return false }
        return workspace.activate(pid: app.pid)
    }

    @discardableResult
    public func quit(bundleID: String) -> Bool {
        guard let app = runningRegularApps().first(where: { $0.bundleID == bundleID }) else { return false }
        return workspace.quit(pid: app.pid)
    }

    // MARK: Changes

    /// Launch, terminate and activate events as `apps.changed` payloads. Background agents are not reported.
    public func changes() -> AsyncStream<AppChangeEvent> {
        _ = runningRegularApps()
        let source = workspace.events()
        let (stream, continuation) = AsyncStream<AppChangeEvent>.makeStream(bufferingPolicy: .bufferingNewest(256))
        let task = Task { [weak self] in
            for await event in source {
                guard let self else { break }
                if let change = await self.translate(event) { continuation.yield(change) }
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    func translate(_ event: WorkspaceEvent) -> AppChangeEvent? {
        switch event {
        case .launched(let app):
            guard app.isRegular, app.bundleID != nil else { return nil }
            knownByPID[app.pid] = app
            return runningInfo(app, windowCounts: [:]).map { AppChangeEvent(change: .launched, app: $0) }
        case .terminated(let pid):
            guard var app = knownByPID.removeValue(forKey: pid) else { return nil }
            app.isActive = false
            return runningInfo(app, windowCounts: [:]).map { AppChangeEvent(change: .terminated, app: $0) }
        case .activated(let pid):
            guard var app = knownByPID[pid] else { return nil }
            for other in knownByPID.keys { knownByPID[other]?.isActive = false }
            app.isActive = true
            knownByPID[pid] = app
            return runningInfo(app, windowCounts: [:]).map { AppChangeEvent(change: .activated, app: $0) }
        }
    }
}
#endif
