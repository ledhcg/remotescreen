#if os(macOS)
import Foundation
@testable import HelperCore

/// A scripted `WorkspaceAccess` for catalog tests.
final class FakeWorkspace: WorkspaceAccess, @unchecked Sendable {
    private let lock = NSLock()
    private var apps: [RunningAppInfo]
    private var continuation: AsyncStream<WorkspaceEvent>.Continuation?
    private(set) var launched: [String] = []
    private(set) var renderRequests: [Int] = []
    var launchError: AppLaunchError?
    /// PNG size produced for a given pixel size; defaults to a small payload.
    var pngSize: @Sendable (Int) -> Int = { _ in 100 }

    init(apps: [RunningAppInfo] = []) { self.apps = apps }

    func setApps(_ new: [RunningAppInfo]) { lock.withLock { apps = new } }

    func runningApps() -> [RunningAppInfo] { lock.withLock { apps } }

    func launch(bundleID: String) async throws {
        if let launchError { throw launchError }
        lock.withLock { launched.append(bundleID) }
    }

    func activate(pid: Int32) -> Bool { lock.withLock { apps.contains { $0.pid == pid } } }
    func quit(pid: Int32) -> Bool { lock.withLock { apps.contains { $0.pid == pid } } }
    func bundleURL(forBundleID bundleID: String) -> URL? { URL(fileURLWithPath: "/Applications/\(bundleID).app") }

    func events() -> AsyncStream<WorkspaceEvent> {
        let (stream, continuation) = AsyncStream<WorkspaceEvent>.makeStream()
        lock.withLock { self.continuation = continuation }
        return stream
    }

    func send(_ event: WorkspaceEvent) { _ = lock.withLock { continuation }?.yield(event) }

    func iconPNG(forBundleAt url: URL, pixelSize: Int) -> Data? {
        lock.withLock { renderRequests.append(pixelSize) }
        return Data(count: pngSize(pixelSize))
    }
}

struct FakeInstalledSource: InstalledAppSource {
    var apps: [InstalledAppInfo]
    func installedApps() -> [InstalledAppInfo] { apps }
}

func tempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("screon-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Writes a minimal `.app` bundle with the given Info.plist entries.
@discardableResult
func makeBundle(in folder: URL, name: String, plist: [String: Any]) throws -> URL {
    let bundle = folder.appendingPathComponent("\(name).app", isDirectory: true)
    try FileManager.default.createDirectory(at: bundle.appendingPathComponent("Contents"), withIntermediateDirectories: true)
    let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    try data.write(to: bundle.appendingPathComponent("Contents/Info.plist"))
    return bundle
}
#endif
