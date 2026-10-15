#if os(macOS)
import AppKit
import Foundation

/// A running application as the catalog sees it.
public struct RunningAppInfo: Sendable, Hashable {
    public var pid: Int32
    public var bundleID: String?
    public var name: String
    public var version: String?
    public var bundleURL: URL?
    public var isActive: Bool
    /// False for background agents and daemons (`NSApplication.ActivationPolicy` other than `.regular`).
    public var isRegular: Bool
    public init(pid: Int32, bundleID: String?, name: String, version: String? = nil, bundleURL: URL? = nil, isActive: Bool = false, isRegular: Bool = true) {
        self.pid = pid; self.bundleID = bundleID; self.name = name; self.version = version; self.bundleURL = bundleURL
        self.isActive = isActive; self.isRegular = isRegular
    }
}

public enum WorkspaceEvent: Sendable, Equatable {
    case launched(RunningAppInfo)
    case terminated(pid: Int32)
    case activated(pid: Int32)
}

public enum AppLaunchError: Error, Sendable, Equatable {
    case notInstalled(String)
    case failed(String)
}

/// Everything the catalog needs from `NSWorkspace`. The fake in the tests makes the catalog testable without launching apps.
public protocol WorkspaceAccess: Sendable {
    func runningApps() -> [RunningAppInfo]
    /// Launches (or activates, when running) the app with this bundle id.
    func launch(bundleID: String) async throws
    func activate(pid: Int32) -> Bool
    /// Asks the app to quit (`terminate()`), never force-quits.
    func quit(pid: Int32) -> Bool
    /// Launch, terminate and activate notifications. One stream per call.
    func events() -> AsyncStream<WorkspaceEvent>
    /// PNG of the icon of the bundle at `url`, `pixelSize` pixels square. `nil` when the icon cannot be rendered.
    func iconPNG(forBundleAt url: URL, pixelSize: Int) -> Data?
    func bundleURL(forBundleID bundleID: String) -> URL?
}

/// The real implementation on `NSWorkspace`.
public final class SystemWorkspaceAccess: WorkspaceAccess, @unchecked Sendable {
    public init() {}

    private static func info(_ app: NSRunningApplication) -> RunningAppInfo {
        var version: String?
        if let url = app.bundleURL { version = Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String }
        return RunningAppInfo(
            pid: app.processIdentifier, bundleID: app.bundleIdentifier, name: app.localizedName ?? app.bundleIdentifier ?? "",
            version: version, bundleURL: app.bundleURL, isActive: app.isActive, isRegular: app.activationPolicy == .regular)
    }

    public func runningApps() -> [RunningAppInfo] {
        NSWorkspace.shared.runningApplications.filter { !$0.isTerminated }.map(Self.info)
    }

    public func bundleURL(forBundleID bundleID: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }

    public func launch(bundleID: String) async throws {
        guard let url = bundleURL(forBundleID: bundleID) else { throw AppLaunchError.notInstalled(bundleID) }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        do {
            _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        } catch {
            throw AppLaunchError.failed(bundleID)
        }
    }

    public func activate(pid: Int32) -> Bool {
        NSRunningApplication(processIdentifier: pid)?.activate(options: []) ?? false
    }

    public func quit(pid: Int32) -> Bool {
        NSRunningApplication(processIdentifier: pid)?.terminate() ?? false
    }

    public func events() -> AsyncStream<WorkspaceEvent> {
        let (stream, continuation) = AsyncStream<WorkspaceEvent>.makeStream(bufferingPolicy: .bufferingNewest(256))
        let center = NSWorkspace.shared.notificationCenter
        @Sendable func app(_ note: Notification) -> NSRunningApplication? { note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication }
        let tokens: [NSObjectProtocol] = [
            center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: nil) { note in
                if let app = app(note) { continuation.yield(.launched(Self.info(app))) }
            },
            center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: nil) { note in
                if let app = app(note) { continuation.yield(.terminated(pid: app.processIdentifier)) }
            },
            center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: nil) { note in
                if let app = app(note) { continuation.yield(.activated(pid: app.processIdentifier)) }
            },
        ]
        let box = ObserverTokens(tokens)
        continuation.onTermination = { _ in box.remove(from: center) }
        return stream
    }

    public func iconPNG(forBundleAt url: URL, pixelSize: Int) -> Data? {
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixelSize, pixelsHigh: pixelSize, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return nil }
        rep.size = NSSize(width: pixelSize, height: pixelSize)
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        icon.draw(in: NSRect(x: 0, y: 0, width: pixelSize, height: pixelSize), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }
}

private final class ObserverTokens: @unchecked Sendable {
    private let tokens: [NSObjectProtocol]
    init(_ tokens: [NSObjectProtocol]) { self.tokens = tokens }
    func remove(from center: NotificationCenter) { for token in tokens { center.removeObserver(token) } }
}
#endif
