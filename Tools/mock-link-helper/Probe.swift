import Foundation
import LinkProtocol
import LinkTransport

/// `--probe <file>`: a diagnostic client for a real Screon Helper (debugging on the maintainer's Mac only). Pairs with the
/// pairing link in `file` (a debug helper writes it with `SCREON_HELPER_QR_OUT`), waits for the snapshot and for the window
/// changes of the next few seconds, and prints only counts and bundle identifiers, never window titles. Never committed output.
enum Probe {
    static func run(linkFile: String, host: String?, subscribeBundle: String? = nil) async -> Int32 {
        do {
            let text = try String(contentsOfFile: linkFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            let payload = try PairingQRPayload.parse(text)
            guard let target = host ?? payload.hostHints.first else { print("probe: no host"); return 2 }
            let identity = try MockIdentity.make(role: .ipad, directory: nil)
            let configuration = LinkClientConfiguration(
                identity: identity, deviceName: "Screon probe", capabilities: [.hevc, .h264],
                sceneLimits: LinkSceneLimits(maxWindows: 8, maxStreams: 8, maxPixelWidth: 1024, maxPixelHeight: 768, maxFramesPerSecond: 30),
                mode: .pairWithQR(payload), pinnedMacSPKIHash: nil, transport: .automatic, quicTimeout: .seconds(3),
                connectTimeout: .seconds(10), sasConfirmation: nil, pairedMacStore: InMemoryPairedMacStore(), computerID: "probe")
            let connection = try await LinkConnection.connect(to: LinkEndpoint(host: target, port: payload.port), configuration: configuration)
            print("probe: connected to \(target):\(payload.port) over \(connection.transport)")
            let control = Collector()
            Task { for await m in connection.controlMessages { await control.add(m) } }
            let video = Collector()
            Task {
                for await event in connection.events {
                    if case .streamOpened(.window, let inbox) = event { Task { for await m in inbox { await video.add(m) } } }
                }
            }
            try? await Task.sleep(for: .seconds(3))
            if let bundle = subscribeBundle {
                let windows = await control.messages.flatMap { m -> [LinkWindowInfo] in
                    if case .snapshot(let s) = m { return s.windows } else { return [] }
                }
                if let target = windows.first(where: { $0.bundleID == bundle && $0.kind == .managed }) {
                    try await connection.send(.windowSubscribe(LinkSubscribe(
                        window: target.id, pixelWidth: 1280, pixelHeight: 800, maxFramesPerSecond: 30, quality: .balanced)))
                    try? await Task.sleep(for: .seconds(5))
                    var configs = 0, frames = 0, keys = 0, bytes = 0
                    for m in await video.messages {
                        if case .videoConfig = m { configs += 1 }
                        if case .videoFrame(let f) = m { frames += 1; bytes += f.data.count; if f.flags.contains(.key) { keys += 1 } }
                    }
                    let failures = await control.messages.filter { if case .windowSubscribeFailed = $0 { true } else { false } }
                    for m in await control.messages {
                        switch m {
                        case .windowDestroyed(let id): print("probe: event window.destroyed \(id.rawValue)\(id == target.id ? " (the subscribed window)" : "")")
                        case .windowCreated(let w): print("probe: event window.created \(w.id.rawValue) \(w.bundleID) \(w.kind)")
                        case .windowUpdated(let u): if u.id == target.id { print("probe: event window.updated (subscribed) flags=\(String(describing: u.flags))") }
                        default: break
                        }
                    }
                    print("probe: subscribed window id \(target.id.rawValue)")
                    print("probe: subscribed to a \(bundle) window: configs=\(configs) frames=\(frames) key=\(keys) bytes=\(bytes) subscribeFailed=\(failures.count)")
                } else {
                    print("probe: no managed window of \(bundle) to subscribe to")
                }
            } else {
                try? await Task.sleep(for: .seconds(3))
            }
            let messages = await control.messages
            var managed: [String: Int] = [:]
            var transient = 0
            for message in messages {
                switch message {
                case .snapshot(let s):
                    print("probe: snapshot apps=\(s.apps.count) windows=\(s.windows.count) version=\(s.stateVersion)")
                    for app in s.apps { print("probe:   app \(app.bundleID) windowCount=\(app.windowCount)") }
                    for w in s.windows { if w.kind == .managed { managed[w.bundleID, default: 0] += 1 } else { transient += 1 } }
                case .windowCreated(let w):
                    if w.kind == .managed { managed[w.bundleID, default: 0] += 1 } else { transient += 1 }
                case .status(let status):
                    print("probe: status \(status)")
                default: break
                }
            }
            print("probe: managed windows by app: \(managed.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" })")
            print("probe: transient windows: \(transient); control messages: \(messages.count)")
            await connection.close()
            return 0
        } catch {
            print("probe: failed: \(error)")
            return 1
        }
    }
}
