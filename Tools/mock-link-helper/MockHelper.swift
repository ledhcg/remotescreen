import CryptoKit
import Foundation
import LinkProtocol
import LinkTransport

enum Scenario: String, Sendable { case basic, churn, locked }
enum PairingMode: String, Sendable { case auto, qr }

struct Options: Sendable {
    var port: UInt16 = 7361
    var logPath: String?
    var scenario: Scenario = .basic
    var pairing: PairingMode = .auto
    var qrOut: String?
    var identityDir: String?
    var inboxDir: String?
    var enableQUIC = true
    var selfTest = false
}

/// The fake Mac: scripted apps and windows, synthetic video, and a log of everything the iPad sends.
actor MockHelper {
    private struct SessionState {
        var connection: LinkServerConnection
        var streamers: [WindowID: WindowStreamer] = [:]
    }

    private struct Transfer {
        var name: String
        var size: UInt64
        var received: UInt64 = 0
        var hasher = SHA256()
        var url: URL
        var handle: FileHandle
    }

    let log: JSONLLog
    private let options: Options
    private let board = MarkerBoard()
    private var server: LinkServer?
    private var apps = Synthetic.apps
    private var windows: [WindowID: LinkWindowInfo] = [:]
    private var order: [WindowID] = []
    private var active: WindowID?
    private var stateVersion: UInt64 = 1
    private var sessions: [UInt64: SessionState] = [:]
    private var transfers: [TransferID: Transfer] = [:]
    private var clipboard: (type: String, data: Data)?
    private var inboxURL: URL
    private let ownsInbox: Bool
    private var background: [Task<Void, Never>] = []
    private var nextChurnID: UInt32 = 100
    private var churnWindows: [WindowID] = []

    init(options: Options, log: JSONLLog) {
        self.options = options
        self.log = log
        if let dir = options.inboxDir {
            inboxURL = URL(fileURLWithPath: dir, isDirectory: true)
            ownsInbox = false
        } else {
            inboxURL = FileManager.default.temporaryDirectory.appendingPathComponent("screon-mock-inbox-\(UUID().uuidString)")
            ownsInbox = true
        }
        for w in Synthetic.basicWindows() { windows[w.id] = w; order.append(w.id) }
        active = 1
    }

    // MARK: Lifecycle

    func start() async throws -> LinkServerEndpoint {
        try FileManager.default.createDirectory(at: inboxURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let identityDir = options.identityDir.map { URL(fileURLWithPath: $0, isDirectory: true) }
        let identity = try MockIdentity.make(role: .helper, directory: identityDir)
        let mode = options.pairing
        let log = self.log
        let configuration = LinkServerConfiguration(
            identity: identity, macName: "Mock Mac", capabilities: [.hevc, .h264, .menus, .files, .clipboardRich, .surfaces, .gestures, .tablet],
            pairedDevices: FilePairedDeviceStore(directory: identityDir),
            approvalHandler: { request in
                // Pairing glue: auto approves everything (test only); qr approves only a device that proved the QR secret.
                let approved: Bool
                switch mode {
                case .auto: approved = true
                case .qr: approved = request.reason == .newPairing(.qr)
                }
                log.write("approval", ["device": request.deviceName, "approved": approved])
                return approved
            },
            displays: { [Synthetic.mainDisplay] },
            snapshotProvider: { [weak self] _ in await self?.snapshot() },
            port: options.port, enableQUIC: options.enableQUIC, enableTCP: true, loopbackOnly: true)
        let server = try LinkServer(configuration: configuration)
        let endpoint = try await server.start()
        self.server = server
        log.write("listening", ["port": Int(endpoint.port), "scenario": options.scenario.rawValue, "pairing": options.pairing.rawValue])
        background.append(Task { [weak self] in
            for await connection in server.connections { await self?.adopt(connection) }
        })
        if options.scenario == .churn {
            background.append(Task { [weak self] in await self?.runChurn() })
        }
        return endpoint
    }

    func stop() async {
        for task in background { task.cancel() }
        background = []
        for (_, state) in sessions { for streamer in state.streamers.values { await streamer.stop() } }
        sessions = [:]
        await server?.stop()
        server = nil
        for (_, transfer) in transfers { try? transfer.handle.close() }
        transfers = [:]
        if ownsInbox { try? FileManager.default.removeItem(at: inboxURL) }
        log.write("stopped")
    }

    /// Issues a fresh pairing secret and returns the QR string. Pairing glue lives here only.
    func pairingQRString() async throws -> String {
        guard let server else { throw MockError.message("not started") }
        let payload = try await server.makePairingQRPayload(hostHints: ["127.0.0.1"])
        return try payload.encoded()
    }

    func pairingQRPayload() async throws -> PairingQRPayload {
        guard let server else { throw MockError.message("not started") }
        return try await server.makePairingQRPayload(hostHints: ["127.0.0.1"])
    }

    // MARK: State

    private func appInfos() -> [LinkAppInfo] {
        let activeBundle = active.flatMap { windows[$0]?.bundleID }
        return apps.map { app in
            LinkAppInfo(
                ref: app.ref, bundleID: app.bundleID, name: app.name, pid: app.pid, iconKey: app.iconKey,
                isActive: app.bundleID == activeBundle,
                windowCount: UInt16(windows.values.filter { $0.bundleID == app.bundleID && $0.kind == .managed }.count))
        }
    }

    func snapshot() -> LinkSnapshot {
        LinkSnapshot(
            stateVersion: stateVersion, apps: appInfos(), windows: order.compactMap { windows[$0] }, activeWindow: active)
    }

    private func broadcast(_ message: LinkMessage) async {
        for state in sessions.values { try? await state.connection.send(message) }
    }

    // MARK: Sessions

    private func adopt(_ connection: LinkServerConnection) {
        let id = connection.session.sessionID
        sessions[id] = SessionState(connection: connection)
        log.write(
            "session",
            ["device": connection.session.deviceName, "paired": true, "newly_paired": connection.session.newlyPaired,
             "resumed": connection.session.resumed])
        if connection.session.newlyPaired { log.write("paired", ["device": connection.session.deviceName]) }
        Task { [weak self] in await self?.runSession(connection, id: id) }
    }

    private func runSession(_ connection: LinkServerConnection, id: UInt64) async {
        if options.scenario == .locked {
            try? await connection.send(.status(.macLocked(true)))
            log.write("status", ["status": "macLocked", "value": true])
        }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { [weak self] in
                for await message in connection.controlMessages { await self?.handle(message, session: id) }
            }
            group.addTask { [weak self] in
                for await event in connection.events {
                    switch event {
                    case .streamOpened(.input, let inbox):
                        Task { [weak self] in
                            for await message in inbox { await self?.handle(message, session: id) }
                        }
                    case .videoBackpressure(let window, let dropped, let needsKey):
                        await self?.backpressure(window, dropped: dropped, needsKey: needsKey, session: id)
                    case .closed:
                        return
                    default: break
                    }
                }
            }
            await group.waitForAll()
        }
        if let state = sessions.removeValue(forKey: id) {
            for streamer in state.streamers.values { await streamer.stop() }
        }
        log.write("session_closed", [:])
    }

    private func backpressure(_ window: WindowID, dropped: Int, needsKey: Bool, session: UInt64) {
        log.write("backpressure", ["window": window.rawValue, "dropped": dropped])
        if needsKey { sessions[session]?.streamers[window]?.requestKeyframe() }
    }

    // MARK: Messages

    private func handle(_ message: LinkMessage, session id: UInt64) async {
        guard let connection = sessions[id]?.connection else { return }
        func reply(_ m: LinkMessage) async { try? await connection.send(m) }
        switch message {
        case .ping(let t): await reply(.pong(timestampMicros: t))
        case .pong: break
        case .stats(let s):
            log.write("stats", ["rtt_micros": Int(s.rttMicros), "windows": s.windows.count])

        case .appsList(let filter):
            log.write("apps_list", ["filter": Int(filter.rawValue)])
            await reply(.appsItems(appInfos()))
        case .appsIcon(let key, let size):
            log.write("apps_icon", ["key": key.rawValue, "size": Int(size)])
            if let app = Synthetic.app(iconKey: key) {
                await reply(.appsIconData(key: key, png: Synthetic.icon(for: app, pixelSize: Int(size))))
            }
        case .appsLaunch(let bundle): log.write("apps_launch", ["bundle": bundle])
        case .appsActivate(let bundle):
            log.write("apps_activate", ["bundle": bundle])
            if let app = Synthetic.app(bundleID: bundle), let w = order.first(where: { windows[$0]?.bundleID == bundle && windows[$0]?.kind == .managed }) {
                await activate(w)
                await broadcast(.appsChanged(change: .activated, app: appInfos().first { $0.ref == app.ref }!))
            }
        case .appsQuit(let bundle): log.write("apps_quit", ["bundle": bundle])

        case .windowSubscribe(let sub): await subscribe(sub, session: id)
        case .windowUnsubscribe(let window):
            log.write("unsubscribe", ["window": window.rawValue])
            await unsubscribe(window, session: id)
        case .streamKeyframe(let window):
            log.write("keyframe_request", ["window": window.rawValue])
            sessions[id]?.streamers[window]?.requestKeyframe()
        case .windowSetFrame(let request):
            log.write(
                "set_frame", ["window": request.window.rawValue, "width": request.size.width, "height": request.size.height,
                              "placement": Int(request.placement.rawValue)])
            if var info = windows[request.window] {
                info.frame.size = request.size
                windows[request.window] = info
                stateVersion += 1
                await broadcast(.windowUpdated(LinkWindowUpdate(id: info.id, stateVersion: stateVersion, frame: info.frame)))
            }
        case .windowCommand(let window, let command):
            log.write("command", ["window": window.rawValue, "command": String(describing: command)])
            switch command {
            case .raise: await activate(window)
            case .close: await destroy(window)
            default: break
            }
        case .videoAck(let window, let tokens): log.write("video_ack", ["window": window.rawValue, "tokens": tokens.count])
        case .videoLost(let window, let first, let last):
            log.write("video_lost", ["window": window.rawValue, "first": Int(first), "last": Int(last)])
            sessions[id]?.streamers[window]?.requestKeyframe()

        case .inputPointer(let e):
            log.write(
                "pointer",
                ["window": e.window.rawValue, "x": e.point.x, "y": e.point.y, "buttons": Int(e.buttons.rawValue),
                 "modifiers": Int(e.modifiers.rawValue)])
            board.set(e.window, e.point)
        case .inputScroll(let e):
            log.write("scroll", ["window": e.window.rawValue, "dx": e.dx, "dy": e.dy, "phase": Int(e.phase.rawValue)])
        case .inputGesture(let e):
            log.write("gesture", ["window": e.window.rawValue, "kind": Int(e.kind.rawValue), "value": e.value, "phase": Int(e.phase.rawValue)])
        case .inputKey(let e):
            log.write(
                "key", ["keycode": Int(e.keycode), "keysym": Int(e.keysym ?? 0), "down": e.down, "modifiers": Int(e.modifiers.rawValue)])
        case .inputText(let text): log.write("text", ["text": text, "utf8_bytes": text.utf8.count])

        case .menuGet(let bundle):
            log.write("menu_get", ["bundle": bundle])
            await reply(.menuTree(bundleID: bundle, items: Synthetic.menuTree()))
        case .menuPress(let bundle, let path): log.write("menu_press", ["bundle": bundle, "path": path.map { Int($0) }])

        case .clipboardOffer(let types):
            log.write("clipboard_offer", ["types": types])
            if let first = types.first { await reply(.clipboardRequest(type: first)) }
        case .clipboardRequest(let type):
            log.write("clipboard_request", ["clip_type": type])
            if let clip = clipboard, clip.type == type { await reply(.clipboardData(type: type, data: clip.data)) }
        case .clipboardData(let type, let data):
            log.write(
                "clipboard_data",
                ["clip_type": type, "bytes": data.count, "text": type.contains("text") ? String(decoding: data.prefix(200), as: UTF8.self) : ""])
            clipboard = (type, data)
            await reply(.clipboardOffer(types: [type]))  // echo

        case .fileBegin(let begin): beginFile(begin)
        case .fileChunk(let chunk): appendFile(chunk)
        case .fileEnd(let transfer, let sha): finishFile(transfer, digest: sha.data)

        default:
            log.write("unexpected", ["message": String(describing: message.type)])
        }
    }

    // MARK: Windows

    private func subscribe(_ sub: LinkSubscribe, session id: UInt64) async {
        log.write(
            "subscribe",
            ["window": sub.window.rawValue, "width": Int(sub.pixelWidth), "height": Int(sub.pixelHeight),
             "fps": Int(sub.maxFramesPerSecond), "quality": Int(sub.quality.rawValue)])
        guard let state = sessions[id], let info = windows[sub.window] else { return }
        await unsubscribe(sub.window, session: id)
        try? await state.connection.send(
            .windowCapabilities(window: sub.window, capabilities: info.kind == .managed ? Synthetic.managedCapabilities : []))
        if info.kind == .transient {
            // A transient surface is delivered as an image, not as video.
            let snapshot = LinkSurfaceSnapshot(
                window: sub.window, id: SurfaceID(rawValue: 1), parentID: nil, offset: LinkPoint(x: 0, y: 0), format: .png,
                data: Synthetic.menuSurfacePNG())
            try? await state.connection.send(.surfaceSnapshot(snapshot))
            return
        }
        let hevc = state.connection.session.capabilities.contains(.hevc)
        let streamer = WindowStreamer(
            subscription: sub, sizePoints: info.frame.size, connection: state.connection, board: board, log: log, preferHEVC: hevc)
        sessions[id]?.streamers[sub.window] = streamer
        streamer.start()
    }

    private func unsubscribe(_ window: WindowID, session id: UInt64) async {
        guard let streamer = sessions[id]?.streamers.removeValue(forKey: window) else { return }
        await streamer.stop()
        await sessions[id]?.connection.finishWindowStream(window)
    }

    private func activate(_ window: WindowID) async {
        guard windows[window] != nil else { return }
        active = window
        order.removeAll { $0 == window }
        order.insert(window, at: 0)
        stateVersion += 1
        await broadcast(.windowOrder(ids: order, active: active))
    }

    private func destroy(_ window: WindowID) async {
        guard windows.removeValue(forKey: window) != nil else { return }
        order.removeAll { $0 == window }
        if active == window { active = order.first }
        stateVersion += 1
        for id in Array(sessions.keys) { await unsubscribe(window, session: id) }
        await broadcast(.windowDestroyed(window))
        await broadcast(.windowOrder(ids: order, active: active))
    }

    /// Windows appear, move and disappear on a timer.
    private func runChurn() async {
        var step = 0
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(1500))
            if Task.isCancelled { return }
            switch step % 3 {
            case 0:
                let id = WindowID(rawValue: nextChurnID)
                nextChurnID += 1
                let app = apps[Int(id.rawValue) % apps.count]
                let info = LinkWindowInfo(
                    id: id, pid: app.pid, bundleID: app.bundleID,
                    frame: LinkRect(x: Double(60 + 30 * churnWindows.count), y: 60, width: 480, height: 320), scale: 2,
                    title: "Churn \(id.rawValue)", flags: [.onScreen])
                windows[id] = info
                order.append(id)
                churnWindows.append(id)
                stateVersion += 1
                log.write("churn", ["op": "create", "window": id.rawValue])
                await broadcast(.windowCreated(info))
                await broadcast(.windowOrder(ids: order, active: active))
            case 1:
                if let id = churnWindows.last, var info = windows[id] {
                    info.frame.origin.x += 40
                    windows[id] = info
                    stateVersion += 1
                    log.write("churn", ["op": "move", "window": id.rawValue])
                    await broadcast(.windowUpdated(LinkWindowUpdate(id: id, stateVersion: stateVersion, frame: info.frame)))
                }
            default:
                if churnWindows.count > 2 {
                    let id = churnWindows.removeFirst()
                    log.write("churn", ["op": "destroy", "window": id.rawValue])
                    await destroy(id)
                }
            }
            step += 1
        }
    }

    // MARK: Files (inbox in a temp directory only)

    private static let maxTransferBytes: UInt64 = 64 << 20

    private func beginFile(_ begin: LinkFileBegin) {
        guard let name = try? LinkFileName.validated(begin.name), begin.size <= Self.maxTransferBytes, transfers.count < 8 else {
            log.write("file_rejected", ["name_bytes": begin.name.utf8.count, "size": Int(clamping: begin.size)])
            return
        }
        var url = inboxURL.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: url.path) { url = inboxURL.appendingPathComponent("\(UUID().uuidString.prefix(8))-\(name)") }
        guard FileManager.default.createFile(atPath: url.path, contents: nil), let handle = FileHandle(forWritingAtPath: url.path) else {
            log.write("file_rejected", ["reason": "cannot create"])
            return
        }
        transfers[begin.transfer] = Transfer(name: name, size: begin.size, url: url, handle: handle)
        log.write("file_begin", ["name": name, "size": Int(clamping: begin.size), "target": begin.targetBundleID ?? ""])
    }

    private func appendFile(_ chunk: LinkFileChunk) {
        guard var t = transfers[chunk.transfer], chunk.offset == t.received, t.received + UInt64(chunk.data.count) <= t.size else {
            if let t = transfers.removeValue(forKey: chunk.transfer) { try? t.handle.close(); try? FileManager.default.removeItem(at: t.url) }
            log.write("file_rejected", ["reason": "bad chunk"])
            return
        }
        try? t.handle.write(contentsOf: chunk.data)
        t.hasher.update(data: chunk.data)
        t.received += UInt64(chunk.data.count)
        transfers[chunk.transfer] = t
    }

    private func finishFile(_ id: TransferID, digest: Data) {
        guard let t = transfers.removeValue(forKey: id) else { return }
        try? t.handle.close()
        let actual = Data(t.hasher.finalize())
        let ok = actual == digest && t.received == t.size
        log.write("file", ["name": t.name, "size": Int(clamping: t.received), "sha256_ok": ok])
        if !ok { try? FileManager.default.removeItem(at: t.url) }
    }
}
