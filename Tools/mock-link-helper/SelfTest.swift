import CryptoKit
import Foundation
import LinkProtocol
import LinkTransport

/// Collects everything a stream delivers so the test can wait for a message by predicate.
actor Collector {
    private(set) var messages: [LinkMessage] = []
    func add(_ m: LinkMessage) { messages.append(m) }

    func first(timeout: Duration = .seconds(8), where predicate: @Sendable (LinkMessage) -> Bool) async -> LinkMessage? {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let m = messages.first(where: predicate) { return m }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return nil
    }

    func count(timeout: Duration = .seconds(8), atLeast n: Int, where predicate: @Sendable (LinkMessage) -> Bool) async -> [LinkMessage] {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            let found = messages.filter(predicate)
            if found.count >= n { return found }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return messages.filter(predicate)
    }
}

/// `--self-test`: starts the helper and an in-process iPad client against it, pairs by QR, subscribes to a window,
/// receives video, sends input and checks the helper logged it. Returns the process exit code.
enum SelfTest {
    static func run() async -> Int32 {
        var failures: [String] = []
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            print("  \(ok ? "PASS" : "FAIL") \(name)\(ok || detail.isEmpty ? "" : ": " + detail)")
            if !ok { failures.append(name) }
        }

        let logPath = FileManager.default.temporaryDirectory.appendingPathComponent("mock-link-selftest-\(UUID().uuidString).jsonl").path
        defer { try? FileManager.default.removeItem(atPath: logPath) }
        var options = Options()
        options.port = 0
        options.logPath = logPath
        options.pairing = .auto
        options.selfTest = true
        let helper: MockHelper
        let endpoint: LinkServerEndpoint
        let payload: PairingQRPayload
        do {
            helper = MockHelper(options: options, log: try JSONLLog(path: logPath))
            endpoint = try await helper.start()
            payload = try await helper.pairingQRPayload()
        } catch {
            print("FAIL: cannot start the helper: \(error)")
            return 1
        }
        print("Self-test against 127.0.0.1:\(endpoint.port)")

        let result = await withTimeoutSeconds(60) { () -> [String] in
            await body(helper: helper, endpoint: endpoint, payload: payload)
        }
        if let result { failures.append(contentsOf: result) } else { failures.append("timed out") }
        await helper.stop()
        helper.log.close()
        print(failures.isEmpty ? "SELF-TEST PASSED" : "SELF-TEST FAILED: \(failures)")
        return failures.isEmpty ? 0 : 1
    }

    /// Returns the failed check names.
    private static func body(helper: MockHelper, endpoint: LinkServerEndpoint, payload: PairingQRPayload) async -> [String] {
        var failures: [String] = []
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            print("  \(ok ? "PASS" : "FAIL") \(name)\(ok || detail.isEmpty ? "" : ": " + detail)")
            if !ok { failures.append(name) }
        }
        let log = helper.log
        do {
            let identity = try MockIdentity.make(role: .ipad, directory: nil)
            let configuration = LinkClientConfiguration(
                identity: identity, deviceName: "Self-test iPad", capabilities: [.hevc, .h264, .gestures, .tablet],
                sceneLimits: LinkSceneLimits(maxWindows: 8, maxStreams: 8, maxPixelWidth: 1024, maxPixelHeight: 768, maxFramesPerSecond: 30),
                mode: .pairWithQR(payload), pinnedMacSPKIHash: nil, transport: .automatic, quicTimeout: .seconds(3),
                connectTimeout: .seconds(10), sasConfirmation: nil, pairedMacStore: InMemoryPairedMacStore(), computerID: "mock")
            let connection = try await LinkConnection.connect(
                to: LinkEndpoint(host: "127.0.0.1", port: endpoint.quicPort ?? endpoint.port, tcpPort: endpoint.tcpPort), configuration: configuration)
            check("paired by QR", connection.newlyPairedMac != nil)
            print("  transport: \(connection.transport)")

            let control = Collector()
            Task { for await m in connection.controlMessages { await control.add(m) } }
            let video = Collector()
            Task {
                for await event in connection.events {
                    if case .streamOpened(.window, let inbox) = event {
                        Task { for await m in inbox { await video.add(m) } }
                    }
                }
            }

            let snapshot = await control.first { if case .snapshot = $0 { true } else { false } }
            if case .snapshot(let s)? = snapshot {
                check("snapshot has 3 apps and 4 windows", s.apps.count == 3 && s.windows.count == 4, "\(s.apps.count) apps, \(s.windows.count) windows")
                check("snapshot has one transient window", s.windows.filter { $0.kind == .transient }.count == 1)
            } else { check("snapshot received", false) }

            // Window subscription and video.
            try await connection.send(
                .windowSubscribe(LinkSubscribe(window: 1, pixelWidth: 640, pixelHeight: 400, maxFramesPerSecond: 30, quality: .balanced)))
            let config = await video.first { if case .videoConfig = $0 { true } else { false } }
            check("video config received", config != nil)
            if case .videoConfig(let c)? = config {
                print("  codec: \(c.codec), \(c.pixelWidth)x\(c.pixelHeight), \(c.parameterSets.count) parameter sets")
                check("parameter sets present", !c.parameterSets.isEmpty)
            }
            let frames = await video.count(atLeast: 3) { if case .videoFrame = $0 { true } else { false } }
            check("at least 3 video frames", frames.count >= 3, "got \(frames.count)")
            if case .videoFrame(let f)? = frames.first {
                check("first frame is a key frame", f.flags.contains(.key))
                let prefix = f.data.count >= 4 ? Int(f.data.prefix(4).reduce(0) { $0 << 8 | Int($1) }) : -1
                check("frame data is length-prefixed", prefix > 0 && prefix + 4 <= f.data.count)
            }
            let before = await video.messages.filter { if case .videoFrame(let f) = $0 { f.flags.contains(.key) } else { false } }.count
            try await connection.send(.streamKeyframe(1))
            let keys = await video.count(atLeast: before + 1) { if case .videoFrame(let f) = $0 { f.flags.contains(.key) } else { false } }
            check("keyframe request produces a key frame", keys.count > before)

            // Input on the input stream.
            try await connection.send(
                .inputPointer(LinkPointerEvent(window: 1, point: LinkPoint(x: 100, y: 80), buttons: [.left], modifiers: [])))
            try await connection.send(
                .inputPointer(LinkPointerEvent(window: 1, point: LinkPoint(x: 100, y: 80), buttons: [], modifiers: [])))
            try await connection.send(.inputKey(LinkKeyEvent(keycode: 0, keysym: 0x61, down: true, modifiers: [])))
            try await connection.send(.inputKey(LinkKeyEvent(keycode: 0, keysym: 0x61, down: false, modifiers: [])))
            try await waitUntil { log.count("pointer") >= 2 && log.count("key") >= 2 }
            check("helper logged pointer and key events", log.count("pointer") >= 2 && log.count("key") >= 2)

            // Round trips.
            try await connection.send(.ping(timestampMicros: 42))
            let pong = await control.first { if case .pong(42) = $0 { true } else { false } }
            check("ping answered", pong != nil)
            try await connection.send(.appsIcon(key: 1, pixelSize: 64))
            let icon = await control.first { if case .appsIconData = $0 { true } else { false } }
            if case .appsIconData(_, let png)? = icon { check("icon is a PNG", png.starts(with: [0x89, 0x50, 0x4E, 0x47])) } else { check("icon received", false) }
            try await connection.send(.menuGet(bundleID: "com.example.notes"))
            let menu = await control.first { if case .menuTree = $0 { true } else { false } }
            check("menu tree received", menu != nil)
            try await connection.send(.clipboardData(type: "public.utf8-plain-text", data: Data("synthetic clipboard".utf8)))
            let echo = await control.first { if case .clipboardOffer = $0 { true } else { false } }
            check("clipboard echoed", echo != nil)

            let file = Data("synthetic file contents".utf8)
            try await connection.send(.fileBegin(LinkFileBegin(transfer: 1, name: "synthetic.txt", size: UInt64(file.count), targetBundleID: nil)))
            try await connection.send(.fileChunk(LinkFileChunk(transfer: 1, offset: 0, data: file)))
            try await connection.send(.fileEnd(transfer: 1, sha256: try LinkBytes32(Data(SHA256.hash(data: file)))))
            try await waitUntil { log.count("file") >= 1 }
            check("file transfer verified", log.count("file") >= 1)

            try await connection.send(.windowUnsubscribe(1))
            await connection.close()
        } catch {
            check("self-test ran without error", false, "\(error)")
        }
        check("log has session and subscribe events", log.count("session") >= 1 && log.count("subscribe") >= 1)
        return failures
    }

    private static func waitUntil(timeout: Duration = .seconds(5), _ condition: @Sendable () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
    }
}

/// Runs `operation`, giving up after `seconds` (returns nil).
func withTimeoutSeconds<T: Sendable>(_ seconds: Double, _ operation: @escaping @Sendable () async -> T) async -> T? {
    await withTaskGroup(of: T?.self) { group in
        group.addTask { await operation() }
        group.addTask {
            try? await Task.sleep(for: .seconds(seconds))
            return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
    }
}
