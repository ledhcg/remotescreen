#if os(macOS)
import Foundation
import LinkProtocol
import Testing
@testable import HelperCore

@Suite(.timeLimit(.minutes(2))) struct AppCatalogTests {
    static func running(_ pid: Int32, _ id: String?, regular: Bool = true, active: Bool = false) -> RunningAppInfo {
        RunningAppInfo(pid: pid, bundleID: id, name: "App \(pid)", version: "1.0", bundleURL: URL(fileURLWithPath: "/Applications/\(id ?? "x").app"),
                       isActive: active, isRegular: regular)
    }

    static func installed(_ id: String, _ name: String, version: String = "1.0") -> InstalledAppInfo {
        InstalledAppInfo(bundleID: id, name: name, version: version, url: URL(fileURLWithPath: "/Applications/\(name).app"))
    }

    @Test func runningListSkipsBackgroundAgentsAndAppsWithoutBundleID() async {
        let workspace = FakeWorkspace(apps: [
            Self.running(1, "com.example.a", active: true), Self.running(2, "com.example.agent", regular: false), Self.running(3, nil),
        ])
        let catalog = AppCatalog(workspace: workspace, installed: FakeInstalledSource(apps: []))
        let apps = await catalog.apps(filter: .running, windowCounts: [1: 3])
        #expect(apps.map(\.bundleID) == ["com.example.a"])
        #expect(apps[0].pid == 1)
        #expect(apps[0].isActive)
        #expect(apps[0].windowCount == 3)
    }

    @Test func refsAndIconKeysAreStablePerApp() async {
        let workspace = FakeWorkspace(apps: [Self.running(1, "com.example.a")])
        let catalog = AppCatalog(workspace: workspace, installed: FakeInstalledSource(apps: [Self.installed("com.example.a", "A"), Self.installed("com.example.b", "B")]))
        let first = await catalog.apps(filter: .installed)
        let second = await catalog.apps(filter: .installed)
        #expect(first == second)
        #expect(Set(first.map(\.ref)).count == 2)
        #expect(Set(first.map(\.iconKey)).count == 2)
        #expect(first.first { $0.bundleID == "com.example.a" }?.pid == 1)
    }

    @Test func installedListIncludesRunningAppsOutsideTheScannedFolders() async {
        let workspace = FakeWorkspace(apps: [Self.running(7, "com.example.portable")])
        let catalog = AppCatalog(workspace: workspace, installed: FakeInstalledSource(apps: [Self.installed("com.example.a", "A")]))
        let ids = await catalog.apps(filter: .installed).map(\.bundleID)
        #expect(Set(ids) == ["com.example.a", "com.example.portable"])
    }

    @Test func installedListIsCappedAtTheProtocolLimit() async {
        let many = (0..<(LinkLimits.maxApps + 50)).map { Self.installed("com.example.app\($0)", "App \($0)") }
        let catalog = AppCatalog(workspace: FakeWorkspace(), installed: FakeInstalledSource(apps: many))
        #expect(await catalog.apps(filter: .installed).count == LinkLimits.maxApps)
    }

    @Test func longNamesAreBoundedForTheWire() async {
        let longName = String(repeating: "Ä", count: 300)
        let catalog = AppCatalog(workspace: FakeWorkspace(apps: [
            RunningAppInfo(pid: 1, bundleID: "com.example.a", name: longName),
        ]), installed: FakeInstalledSource(apps: []))
        let name = await catalog.apps(filter: .running)[0].name
        #expect(name.utf8.count <= LinkLimits.maxNameBytes)
        #expect(!name.isEmpty)
    }

    // MARK: Recents

    @Test func launchRecordsRecentsNewestFirstAndPersistsThem() async throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("recent.json")
        let installed = FakeInstalledSource(apps: ["a", "b", "c"].map { Self.installed("com.example.\($0)", $0.uppercased()) })
        let workspace = FakeWorkspace()
        let catalog = AppCatalog(workspace: workspace, installed: installed, recentsURL: file, recentsLimit: 2)
        try await catalog.launch(bundleID: "com.example.a")
        try await catalog.launch(bundleID: "com.example.b")
        try await catalog.launch(bundleID: "com.example.a")
        try await catalog.launch(bundleID: "com.example.c")
        #expect(await catalog.recentBundleIDs() == ["com.example.c", "com.example.a"])
        #expect(workspace.launched.count == 4)

        let reloaded = AppCatalog(workspace: workspace, installed: installed, recentsURL: file, recentsLimit: 2)
        #expect(await reloaded.apps(filter: .recent).map(\.bundleID) == ["com.example.c", "com.example.a"])

        // Only bundle ids are stored: no paths, titles or documents.
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(!text.contains("/"))
    }

    @Test func failedLaunchIsNotRecorded() async throws {
        let workspace = FakeWorkspace()
        workspace.launchError = .notInstalled("com.example.a")
        let catalog = AppCatalog(workspace: workspace, installed: FakeInstalledSource(apps: []))
        await #expect(throws: AppLaunchError.self) { try await catalog.launch(bundleID: "com.example.a") }
        #expect(await catalog.recentBundleIDs().isEmpty)
    }

    @Test func corruptOrHostileRecentsFileIsIgnored() throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("recent.json")
        try Data("not json".utf8).write(to: file)
        #expect(RecentApps.load(from: file).bundleIDs.isEmpty)
        let huge = (0..<100).map { "\"com.example.\($0)\"" }.joined(separator: ",")
        try Data("{\"version\":1,\"bundleIDs\":[\(huge),\"\(String(repeating: "x", count: 300))\"]}".utf8).write(to: file)
        #expect(RecentApps.load(from: file, limit: 5).bundleIDs.count == 5)
        try Data("{\"version\":2,\"bundleIDs\":[\"a\"]}".utf8).write(to: file)
        #expect(RecentApps.load(from: file).bundleIDs.isEmpty)
    }

    // MARK: Icons

    @Test func iconSizesAreClamped() async {
        let workspace = FakeWorkspace(apps: [Self.running(1, "com.example.a")])
        let catalog = AppCatalog(workspace: workspace, installed: FakeInstalledSource(apps: []))
        let key = await catalog.apps(filter: .running)[0].iconKey
        _ = await catalog.iconPNG(key: key, pixelSize: 1)
        _ = await catalog.iconPNG(key: key, pixelSize: 5000)
        _ = await catalog.iconPNG(key: key, pixelSize: 100)
        #expect(workspace.renderRequests == [16, 512, 100])
        #expect(AppCatalog.clampedIconSize(-5) == 16)
        #expect(AppCatalog.clampedIconSize(Int.max) == 512)
    }

    @Test func iconsAreCachedByBundleVersionAndSize() async {
        let workspace = FakeWorkspace(apps: [Self.running(1, "com.example.a")])
        let catalog = AppCatalog(workspace: workspace, installed: FakeInstalledSource(apps: []))
        let key = await catalog.apps(filter: .running)[0].iconKey
        let first = await catalog.iconPNG(key: key, pixelSize: 64)
        let again = await catalog.iconPNG(key: key, pixelSize: 64)
        _ = await catalog.iconPNG(key: key, pixelSize: 128)
        #expect(first == again)
        #expect(workspace.renderRequests == [64, 128])

        // A new version of the same app gets a new key.
        workspace.setApps([RunningAppInfo(pid: 1, bundleID: "com.example.a", name: "A", version: "2.0", bundleURL: URL(fileURLWithPath: "/Applications/a.app"))])
        let newKey = await catalog.apps(filter: .running)[0].iconKey
        #expect(newKey != key)
    }

    @Test func oversizedIconIsReRenderedSmallerAndUnknownKeyIsNil() async {
        let workspace = FakeWorkspace(apps: [Self.running(1, "com.example.a")])
        workspace.pngSize = { size in size > 128 ? LinkLimits.maxIconPNGBytes + 1 : 500 }
        let catalog = AppCatalog(workspace: workspace, installed: FakeInstalledSource(apps: []))
        let key = await catalog.apps(filter: .running)[0].iconKey
        let png = await catalog.iconPNG(key: key, pixelSize: 512)
        #expect(png?.count == 500)
        #expect(workspace.renderRequests == [512, 256, 128])
        #expect(await catalog.iconPNG(key: IconKey(9999)) == nil)
    }

    @Test func iconThatIsAlwaysTooBigGivesNil() async {
        let workspace = FakeWorkspace(apps: [Self.running(1, "com.example.a")])
        workspace.pngSize = { _ in LinkLimits.maxIconPNGBytes + 1 }
        let catalog = AppCatalog(workspace: workspace, installed: FakeInstalledSource(apps: []))
        let key = await catalog.apps(filter: .running)[0].iconKey
        #expect(await catalog.iconPNG(key: key, pixelSize: 64) == nil)
    }

    // MARK: Changes

    @Test func workspaceEventsBecomeAppChanges() async {
        let workspace = FakeWorkspace(apps: [Self.running(1, "com.example.a")])
        let catalog = AppCatalog(workspace: workspace, installed: FakeInstalledSource(apps: []))
        var iterator = await catalog.changes().makeAsyncIterator()
        workspace.send(.launched(Self.running(2, "com.example.b")))
        workspace.send(.activated(pid: 2))
        workspace.send(.launched(Self.running(3, "com.example.agent", regular: false)))
        workspace.send(.terminated(pid: 3))
        workspace.send(.terminated(pid: 2))
        let launched = await iterator.next()
        let activated = await iterator.next()
        let terminated = await iterator.next()
        #expect(launched?.change == .launched && launched?.app.bundleID == "com.example.b")
        #expect(activated?.change == .activated && activated?.app.isActive == true)
        #expect(terminated?.change == .terminated && terminated?.app.bundleID == "com.example.b" && terminated?.app.isActive == false)
    }
}

@Suite(.timeLimit(.minutes(2))) struct FileManagerAppScannerTests {
    func plist(_ id: String, name: String? = nil, type: String = "APPL", extra: [String: Any] = [:]) -> [String: Any] {
        var dict: [String: Any] = ["CFBundleIdentifier": id, "CFBundlePackageType": type, "CFBundleShortVersionString": "2.1"]
        if let name { dict["CFBundleName"] = name }
        return dict.merging(extra) { _, new in new }
    }

    @Test func findsAppsDeduplicatesAndIgnoresNonApps() throws {
        let root = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("first"), second = root.appendingPathComponent("second")
        try FileManager.default.createDirectory(at: first.appendingPathComponent("Utilities"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        try makeBundle(in: first, name: "Alpha", plist: plist("com.example.alpha", name: "Alpha"))
        try makeBundle(in: first.appendingPathComponent("Utilities"), name: "Tool", plist: plist("com.example.tool"))
        try makeBundle(in: second, name: "Alpha Copy", plist: plist("com.example.alpha", name: "Alpha Copy"))
        try makeBundle(in: second, name: "Framework", plist: plist("com.example.fw", type: "FMWK"))
        try makeBundle(in: second, name: "Agent", plist: plist("com.example.agent", extra: ["LSBackgroundOnly": true]))
        try makeBundle(in: second, name: "NoID", plist: ["CFBundlePackageType": "APPL"])
        try makeBundle(in: second, name: "Beta", plist: plist("com.example.beta", name: "Beta"))
        try FileManager.default.createDirectory(at: second.appendingPathComponent("Empty.app"), withIntermediateDirectories: true)

        let apps = FileManagerAppScanner(roots: [first, second, root.appendingPathComponent("missing")]).installedApps()
        #expect(apps.map(\.bundleID) == ["com.example.alpha", "com.example.beta", "com.example.tool"])
        #expect(apps.first { $0.bundleID == "com.example.alpha" }?.name == "Alpha")
        #expect(apps.first { $0.bundleID == "com.example.tool" }?.name == "Tool")
        #expect(apps[0].version == "2.1")
    }

    @Test func scanIsBounded() throws {
        let root = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        for index in 0..<10 { try makeBundle(in: root, name: "App\(index)", plist: plist("com.example.app\(index)")) }
        #expect(FileManagerAppScanner(roots: [root], maxApps: 4).installedApps().count == 4)

        // Too deep: level 3 with maxDepth 1.
        let deep = root.appendingPathComponent("a/b/c")
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        try makeBundle(in: deep, name: "Deep", plist: plist("com.example.deep"))
        let found = FileManagerAppScanner(roots: [root], maxApps: 100, maxDepth: 1).installedApps()
        #expect(!found.contains { $0.bundleID == "com.example.deep" })
        #expect(FileManagerAppScanner(roots: [root], maxApps: 100, maxDepth: 3).installedApps().contains { $0.bundleID == "com.example.deep" })
    }

    @Test func hugeNamesAreBounded() throws {
        let root = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try makeBundle(in: root, name: "Big", plist: plist("com.example.big", name: String(repeating: "x", count: 5000)))
        let app = try #require(FileManagerAppScanner(roots: [root]).installedApps().first)
        #expect(app.name.utf8.count <= LinkLimits.maxNameBytes)
    }
}
#endif
