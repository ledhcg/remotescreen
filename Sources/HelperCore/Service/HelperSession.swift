#if os(macOS)
import CoreVideo
import Foundation
import LinkProtocol
import os

/// Everything the helper does for one connected iPad (design §4.4–§4.10). Created and owned by `HelperService`.
///
/// Authorisation: the iPad can only act on windows it subscribed to, and a subscription needs a window that exists in the
/// tracker. Input, window commands, frame requests, menus (app of a subscribed window), clipboard and files (any subscribed
/// window) are dropped otherwise. Every collection is bounded.
actor HelperSession: HelperConnectionHandler {
    /// Seconds between key frames the iPad may force on one window.
    static let minKeyFrameInterval = 0.1
    static let maxOpenTransfers = 4
    static let maxPixelBufferDimension = Int(LinkLimits.maxPixelDimension)
    /// Apps the iPad may not quit (the helper itself and the parts of macOS the Mac user could not recover from).
    static let protectedBundleIDs: Set<String> = ["com.apple.finder", "com.apple.loginwindow", "com.apple.dock", "com.apple.systemuiserver"]

    private final class WindowStream {
        let window: WindowID
        let token: Int
        let pid: Int32
        let bundleID: String
        var request: CaptureRequest
        var native: LinkSize
        let requestedFPS: Int
        let quality: LinkQualityTier
        var encoder: (any VideoEncoding)?
        var encoderGeneration = 0
        var encoderWidth = 0
        var encoderHeight = 0
        var encoderTask: Task<Void, Never>?
        var captureTask: Task<Void, Never>?
        var lastFrame: CapturedFrame?
        var lastPTS: UInt64 = 0
        var pending = EncodeOptions()
        var target: WindowTarget?
        var appliedFPS: Int
        var paused = false
        var isIdle = false
        var sets: EncodedParameterSets?
        var configSent = false
        var hasAck = false
        var lastKeyRequest = -Double.infinity
        var encoderFailures = 0

        init(window: WindowID, token: Int, pid: Int32, bundleID: String, request: CaptureRequest, native: LinkSize, quality: LinkQualityTier) {
            self.window = window; self.token = token; self.pid = pid; self.bundleID = bundleID; self.request = request
            self.native = native; self.requestedFPS = request.framesPerSecond; self.quality = quality
            appliedFPS = request.framesPerSecond
        }

        func stop() {
            captureTask?.cancel(); captureTask = nil
            encoderTask?.cancel(); encoderTask = nil
            encoder?.invalidate(); encoder = nil
            lastFrame = nil
        }
    }

    private struct AudioRun {
        var task: Task<Void, Never>
    }

    nonisolated let connection: any HelperConnection
    private let host: any HelperSessionHost
    private let resources: HelperResources
    private let capture: CaptureEngine
    private let clipboard: PasteboardBridge
    private var rate: RateController
    private var streams: [WindowID: WindowStream] = [:]
    private var focused: WindowID?
    private var transfers: [TransferID: TransferID] = [:]
    private var audioRuns: [Int32: AudioRun] = [:]
    private var tasks: [Task<Void, Never>] = []
    private var nextToken = 0
    private var snapshotVersion: UInt64 = 0
    private var started = false
    /// The snapshot is out: status changes may be delivered (they would otherwise arrive before the snapshot).
    private var ready = false
    private var closed = false
    /// The transport ended; nothing more can be sent but cleanup is still due.
    private var transportGone = false
    private let log = Logger(subsystem: "app.screon.helper", category: "session")

    init(connection: any HelperConnection, host: any HelperSessionHost, resources: HelperResources) {
        self.connection = connection
        self.host = host
        self.resources = resources
        capture = CaptureEngine(system: resources.capture)
        clipboard = resources.makeClipboard()
        rate = RateController(clock: resources.options.clock)
    }

    nonisolated var id: UInt64 { connection.info.sessionID }
    private var info: HelperConnectionInfo { connection.info }
    var subscribedWindows: Set<WindowID> { Set(streams.keys) }
    var isClosed: Bool { closed }

    private var maxSubscriptions: Int {
        var limit = resources.options.maxSubscriptionsPerSession
        let announced = Int(info.sceneLimits.maxStreams)
        if announced > 0 { limit = min(limit, announced) }
        return max(limit, 1)
    }

    // MARK: Lifecycle

    /// Subscribes to changes, sends the snapshot and the current conditions, and starts the background loops.
    func start() async {
        guard !started, !closed else { return }
        started = true
        // Subscribe first, snapshot second: a change between the two is either in the snapshot or delivered afterwards, and
        // anything at or below the snapshot's version is skipped.
        let trackerEvents = await resources.tracker.events()
        let appChanges = await resources.catalog.changes()
        let counts = await resources.tracker.windowCounts()
        let apps = await resources.catalog.apps(filter: .running, windowCounts: counts)
        let snapshot = await resources.tracker.linkSnapshot(apps: apps)
        snapshotVersion = snapshot.stateVersion
        await send(.snapshot(snapshot))
        ready = true
        await sendConditions()

        tasks.append(Task { [weak self] in
            for await event in trackerEvents { await self?.trackerEvent(event) }
        })
        tasks.append(Task { [weak self] in
            for await change in appChanges { await self?.appChanged(change) }
        })
        let interval = resources.options.clipboardPollInterval
        tasks.append(Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else { return }
                await self?.offerClipboard()
            }
        })
    }

    /// Idempotent. Stops every stream, releases input, aborts transfers; closes the connection when `code` is given.
    func shutdown(closing code: LinkCloseCode? = nil) async {
        guard !closed else {
            if let code { await connection.close(code: code, reason: "") }
            return
        }
        closed = true
        for task in tasks { task.cancel() }
        tasks = []
        let windows = Set(streams.keys)
        for stream in streams.values { stream.stop() }
        streams = [:]
        await capture.unsubscribeAll()
        for pid in Array(audioRuns.keys) { await stopAudio(pid: pid) }
        if let inbox = resources.inbox { for id in transfers.values { await inbox.abort(id) } }
        transfers = [:]
        await host.subscriptionsChanged(session: id, added: [], removed: windows)
        if let code { await connection.close(code: code, reason: "") }
    }

    // MARK: Sending

    @discardableResult
    private func send(_ message: LinkMessage) async -> Bool {
        guard !closed, !transportGone else { return false }
        do {
            try await connection.send(message)
            return true
        } catch {
            log.debug("send failed: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    /// Delivers a condition change decided by the service (lock state, permissions, stage, secure input).
    func deliver(status: LinkStatus) async {
        guard ready else { return }
        await send(.status(status))
    }

    private func sendConditions() async {
        let c = await host.conditions()
        for (kind, state) in [(LinkPermissionKind.accessibility, c.accessibility), (.screenRecording, c.screenRecording)] {
            await send(.status(.permission(kind, state)))
            if state != .granted { await send(.status(.permissionMissing(kind))) }
        }
        await send(.status(.stage(c.stage)))
        if c.stage == .unavailable { await send(.status(.stageUnavailable)) }
        if c.macLocked { await send(.status(.macLocked(true))) }
        if c.secureInput { await send(.status(.secureInput(pid: c.frontmostPID))) }
    }

    // MARK: Changes from the Mac

    private func trackerEvent(_ event: WindowTrackerEvent) async {
        guard !closed else { return }
        if let version = event.stateVersion, version <= snapshotVersion { return }
        guard let message = event.message else { return }
        if case .destroyed(let window, _) = event { await unsubscribe(window, tellDevice: false) }
        if case .order(_, let active, _) = event, let active, streams[active] != nil, focused != active {
            focused = active
            await updateRate()
        }
        await send(message)
    }

    private func appChanged(_ event: AppChangeEvent) async {
        var app = event.app
        if let pid = app.pid { app.windowCount = UInt16(clamping: await resources.tracker.windowCounts()[pid] ?? 0) }
        await send(.appsChanged(change: event.change, app: app))
    }

    private func offerClipboard() async {
        guard !closed, !streams.isEmpty, let offer = await clipboard.offer() else { return }
        await send(offer)
    }

    // MARK: Control messages

    func handleControl(_ message: LinkMessage) async {
        guard !closed else { return }
        switch message {
        case .appsList(let filter):
            let counts = await resources.tracker.windowCounts()
            await send(.appsItems(await resources.catalog.apps(filter: filter, windowCounts: counts)))
        case .appsIcon(let key, let pixelSize):
            if let png = await resources.catalog.iconPNG(key: key, pixelSize: Int(pixelSize)) { await send(.appsIconData(key: key, png: png)) }
        case .appsLaunch(let bundleID):
            guard Self.isAcceptableBundleID(bundleID) else { return }
            do { try await resources.catalog.launch(bundleID: bundleID) } catch { log.notice("launch failed") }
        case .appsActivate(let bundleID):
            guard Self.isAcceptableBundleID(bundleID) else { return }
            _ = await resources.catalog.activate(bundleID: bundleID)
        case .appsQuit(let bundleID):
            guard Self.isAcceptableBundleID(bundleID), !Self.protectedBundleIDs.contains(bundleID),
                  bundleID != Bundle.main.bundleIdentifier else { return }
            _ = await resources.catalog.quit(bundleID: bundleID)

        case .windowSubscribe(let request): await subscribe(request)
        case .windowUnsubscribe(let window): await unsubscribe(window, tellDevice: true)
        case .windowSetFrame(let request): await setFrame(request)
        case .windowCommand(let window, let command): await perform(command, on: window)
        case .streamKeyframe(let window): await requestKeyFrame(window)
        case .videoAck(let window, let tokens): acknowledge(window, tokens: tokens)
        case .videoLost(let window, _, _): await recoverLoss(window)
        case .stats(let stats): await ingest(stats)

        case .menuGet(let bundleID): await menuTree(bundleID)
        case .menuPress(let bundleID, let path): await pressMenu(bundleID, path: path)

        case .clipboardOffer, .clipboardRequest, .clipboardData: await handleClipboard(message)
        case .fileBegin(let begin): await fileBegin(begin)
        case .fileChunk(let chunk): await fileChunk(chunk)
        case .fileEnd(let transfer, let sha256): await fileEnd(transfer, sha256: sha256)

        default: break  // Handshake leftovers and helper-to-iPad messages: nothing to do.
        }
    }

    private static func isAcceptableBundleID(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= LinkLimits.maxBundleIDBytes
    }

    func handleInput(_ message: LinkMessage) async {
        guard !closed else { return }
        switch message {
        case .inputPointer(let event):
            guard streams[event.window] != nil else { return }
            if !event.buttons.isEmpty, focused != event.window { focused = event.window; await updateRate() }
            await host.inject(message, keyboardWindow: nil)
        case .inputScroll(let event):
            guard streams[event.window] != nil else { return }
            await host.inject(message, keyboardWindow: nil)
        case .inputGesture(let event):
            guard streams[event.window] != nil else { return }
            await host.inject(message, keyboardWindow: nil)
        case .inputKey, .inputText:
            guard let target = focused, streams[target] != nil else { return }
            await host.inject(message, keyboardWindow: target)
        default:
            break
        }
    }

    func handleEvent(_ event: HelperConnectionEvent) async {
        switch event {
        case .videoBackpressure(let window, _, let needsKeyframe):
            if needsKeyframe { await requestKeyFrame(window) }
        case .closed:
            // The transport is gone: stop sending, the service tears the rest down when `run` returns.
            transportGone = true
        }
    }

    // MARK: Subscriptions

    private func subscribe(_ request: LinkSubscribe) async {
        guard let info = await resources.tracker.info(of: request.window), info.kind == .managed else { return }
        if streams[request.window] != nil { await unsubscribe(request.window, tellDevice: false) }
        guard streams.count < maxSubscriptions else {
            log.notice("subscription refused: limit of \(self.maxSubscriptions, privacy: .public) windows reached")
            return
        }
        let permission = resources.permissions.state(of: .screenRecording)
        guard permission == .granted else {
            await send(.status(.permission(.screenRecording, permission)))
            await send(.status(.permissionMissing(.screenRecording)))
            await host.reportPermissionDenied(.screenRecording)
            return
        }

        let limits = self.info.sceneLimits
        var fpsCap = Int(LinkLimits.maxFramesPerSecond)
        if limits.maxFramesPerSecond > 0 { fpsCap = min(fpsCap, Int(limits.maxFramesPerSecond)) }
        let fps = min(max(Int(request.maxFramesPerSecond), 1), fpsCap)
        func capped(_ value: UInt32, _ limit: UInt32) -> UInt32 {
            var result = min(value, LinkLimits.maxPixelDimension)
            if limit > 0 { result = min(result, limit) }
            return result
        }
        let capRequest = CaptureRequest(
            targetPixelWidth: capped(request.pixelWidth, limits.maxPixelWidth),
            targetPixelHeight: capped(request.pixelHeight, limits.maxPixelHeight), framesPerSecond: fps)
        let scale = info.scale > 0 ? info.scale : 1
        let native = LinkSize(width: (info.frame.size.width * scale).rounded(), height: (info.frame.size.height * scale).rounded())

        let events: AsyncStream<CaptureEvent>
        do {
            events = try await capture.subscribe(window: request.window, nativePixelSize: native, request: capRequest)
        } catch let error as CaptureSystemError {
            if error.kind == .permissionDenied {
                await send(.status(.permission(.screenRecording, .denied)))
                await send(.status(.permissionMissing(.screenRecording)))
                await host.reportPermissionDenied(.screenRecording)
            }
            return
        } catch {
            return
        }
        guard !closed else {
            await capture.unsubscribe(window: request.window)
            return
        }

        nextToken += 1
        let stream = WindowStream(
            window: request.window, token: nextToken, pid: info.pid, bundleID: info.bundleID, request: capRequest, native: native,
            quality: request.quality)
        stream.pending.forceKeyFrame = true
        let window = request.window, token = stream.token
        stream.captureTask = Task { [weak self] in
            for await event in events { await self?.captureEvent(event, window: window, token: token) }
        }
        streams[request.window] = stream
        if focused == nil { focused = request.window }

        await host.subscriptionsChanged(session: id, added: [request.window], removed: [])
        await send(.windowCapabilities(window: request.window, capabilities: Self.capabilities(of: info, negotiated: self.info.capabilities)))
        await startAudio(pid: info.pid)
        await updateRate()
    }

    private static func capabilities(of window: LinkWindowInfo, negotiated: LinkCapabilities) -> LinkWindowCapabilities {
        var caps: LinkWindowCapabilities = [.closable]
        if !window.flags.contains(.fullScreen) { caps.formUnion([.resizable, .movable, .minimisable, .zoomable]) }
        if negotiated.contains(.tablet) { caps.insert(.supportsTablet) }
        if negotiated.contains(.menus) { caps.insert(.menuAvailable) }
        return caps
    }

    private func unsubscribe(_ window: WindowID, tellDevice: Bool) async {
        guard let stream = streams.removeValue(forKey: window) else { return }
        stream.stop()
        await capture.unsubscribe(window: window)
        if focused == window { focused = streams.keys.sorted().first }
        await host.subscriptionsChanged(session: id, added: [], removed: [window])
        if !streams.values.contains(where: { $0.pid == stream.pid }) { await stopAudio(pid: stream.pid) }
        await updateRate()
        if !closed, !transportGone {
            let connection = connection
            Task { await connection.finishWindowStream(window) }
        }
    }

    private func setFrame(_ request: LinkSetFrame) async {
        guard streams[request.window] != nil, request.size.isValid, request.size.width > 0, request.size.height > 0 else { return }
        await host.requestStageSize(window: request.window, size: request.size)
    }

    private func perform(_ command: LinkWindowCommand, on window: WindowID) async {
        if command != .raise { guard streams[window] != nil else { return } }
        do {
            if command == .raise, let info = await resources.tracker.info(of: window), info.flags.contains(.minimised) {
                try await resources.tracker.restoreFromMinimised(window: window)
            }
            try await resources.tracker.perform(command, on: window)
            if command == .raise, streams[window] != nil, focused != window { focused = window; await updateRate() }
        } catch {
            log.notice("window command failed")
        }
    }

    // MARK: Video

    private func captureEvent(_ event: CaptureEvent, window: WindowID, token: Int) async {
        guard let stream = streams[window], stream.token == token, !closed else { return }
        switch event {
        case .frame(let frame):
            stream.lastFrame = frame
            guard !stream.paused else { return }
            await encode(frame, stream)
        case .resized:
            break  // The next frame has the new size; `encode` recreates the encoder when the buffer size changed.
        case .idle:
            stream.isIdle = true
            await updateRate()
        case .active:
            stream.isIdle = false
            await updateRate()
        case .restarting:
            break
        case .failed(let failure):
            switch failure {
            case .permission(let state):
                _ = state
                await send(.status(.permission(.screenRecording, .denied)))
                await send(.status(.permissionMissing(.screenRecording)))
                await host.reportPermissionDenied(.screenRecording)
            case .windowGone, .stoppedByUser, .exhausted:
                break
            }
            await unsubscribe(window, tellDevice: true)
        }
    }

    private func encode(_ frame: CapturedFrame, _ stream: WindowStream, extra: EncodeOptions = EncodeOptions()) async {
        guard let buffer = frame.pixelBuffer else { return }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        guard width > 0, height > 0, width <= Self.maxPixelBufferDimension, height <= Self.maxPixelBufferDimension else { return }
        if stream.encoder == nil || stream.encoderWidth != width || stream.encoderHeight != height {
            guard makeEncoder(for: stream, width: width, height: height) else {
                if stream.encoderFailures >= 3 { await unsubscribe(stream.window, tellDevice: true) }
                return
            }
        }
        guard let encoder = stream.encoder else { return }
        var options = stream.pending
        options.forceKeyFrame = options.forceKeyFrame || extra.forceKeyFrame
        options.forceLTRRefresh = options.forceLTRRefresh || extra.forceLTRRefresh
        stream.pending = EncodeOptions()
        let proposed = frame.metadata.ptsMicros
        let pts = proposed > stream.lastPTS ? proposed : stream.lastPTS + 1000
        do {
            try encoder.encode(buffer, ptsMicros: pts, options: options)
            stream.lastPTS = pts
            stream.encoderFailures = 0
        } catch {
            if options.forceKeyFrame { stream.pending.forceKeyFrame = true }
            stream.encoderFailures += 1
            if case VideoEncoderError.invalidSettings = error { stream.encoder?.invalidate(); stream.encoder = nil }
            if stream.encoderFailures >= 30 { await unsubscribe(stream.window, tellDevice: true) }
        }
    }

    private func makeEncoder(for stream: WindowStream, width: Int, height: Int) -> Bool {
        stream.encoderTask?.cancel()
        stream.encoder?.invalidate()
        stream.encoder = nil
        let caps = info.capabilities
        var codec = resources.options.preferredCodec
        if codec == .hevc, !caps.contains(.hevc), caps.contains(.h264) { codec = .h264 }
        if codec == .h264, !caps.contains(.h264), caps.contains(.hevc) { codec = .hevc }
        let target = stream.target.flatMap { $0.isPaused ? nil : $0 }
        let settings = EncoderSettings(
            window: stream.window, preferredCodec: codec, width: width, height: height, bitrate: target?.bitrate ?? 8_000_000,
            framesPerSecond: target?.framesPerSecond ?? stream.request.framesPerSecond,
            enableLongTermReferences: caps.contains(.ltr))
        let encoder: any VideoEncoding
        do { encoder = try resources.makeEncoder(settings) } catch {
            stream.encoderFailures += 1
            log.error("encoder creation failed: \(String(describing: error), privacy: .public)")
            return false
        }
        stream.encoderGeneration += 1
        stream.encoder = encoder
        stream.encoderWidth = width
        stream.encoderHeight = height
        stream.configSent = false
        stream.sets = nil
        stream.pending.forceKeyFrame = true
        let window = stream.window, token = stream.token, generation = stream.encoderGeneration
        let events = encoder.events
        stream.encoderTask = Task { [weak self] in
            for await event in events { await self?.encoderEvent(event, window: window, token: token, generation: generation) }
        }
        return true
    }

    private func encoderEvent(_ event: EncoderEvent, window: WindowID, token: Int, generation: Int) async {
        guard let stream = streams[window], stream.token == token, stream.encoderGeneration == generation, !closed else { return }
        switch event {
        case .parameterSets(let sets):
            stream.sets = sets
            await sendConfig(stream)
        case .frame(let frame):
            if !stream.configSent { await sendConfig(stream) }
            guard stream.configSent else { return }
            await send(.videoFrame(frame))
        case .oversizedDropped:
            stream.pending.forceKeyFrame = true
        }
    }

    private func sendConfig(_ stream: WindowStream) async {
        guard let sets = stream.sets else { return }
        let meta = stream.lastFrame?.metadata
        let content = meta?.contentRect ?? LinkRect(x: 0, y: 0, width: Double(sets.width), height: Double(sets.height))
        let config = sets.makeConfig(window: stream.window, contentRect: content, scale: meta?.scaleFactor ?? 2)
        if await send(.videoConfig(config)) { stream.configSent = true }
    }

    /// Encodes the newest frame again with `options` (a key frame or a refresh for a window that has stopped changing).
    private func reencode(_ stream: WindowStream, _ options: EncodeOptions) async {
        if let frame = stream.lastFrame, !stream.paused {
            await encode(frame, stream, extra: options)
        } else {
            stream.pending.forceKeyFrame = stream.pending.forceKeyFrame || options.forceKeyFrame
            stream.pending.forceLTRRefresh = stream.pending.forceLTRRefresh || options.forceLTRRefresh
        }
    }

    private func requestKeyFrame(_ window: WindowID) async {
        guard let stream = streams[window] else { return }
        let now = resources.options.clock()
        guard now - stream.lastKeyRequest >= Self.minKeyFrameInterval else { return }
        stream.lastKeyRequest = now
        await reencode(stream, EncodeOptions(forceKeyFrame: true))
    }

    private func acknowledge(_ window: WindowID, tokens: [UInt32]) {
        guard let stream = streams[window], !tokens.isEmpty else { return }
        stream.encoder?.acknowledgeLongTermReferences(sequences: Array(tokens.prefix(LinkLimits.maxLTRTokens)))
        stream.hasAck = true
    }

    private func recoverLoss(_ window: WindowID) async {
        guard let stream = streams[window] else { return }
        let now = resources.options.clock()
        guard now - stream.lastKeyRequest >= Self.minKeyFrameInterval else { return }
        stream.lastKeyRequest = now
        // A refresh from a long-term reference only works once the iPad acknowledged one; until then a key frame.
        if stream.hasAck, stream.encoder?.info.longTermReferences == true {
            await reencode(stream, EncodeOptions(forceLTRRefresh: true))
        } else {
            await reencode(stream, EncodeOptions(forceKeyFrame: true))
        }
    }

    // MARK: Rate control

    private func rateWindows() -> [RateWindow] {
        streams.values.sorted { $0.window < $1.window }.map { stream in
            let size = stream.encoderWidth > 0
                ? (width: stream.encoderWidth, height: stream.encoderHeight)
                : CaptureSizing.outputSize(native: stream.native, request: stream.request)
            return RateWindow(
                id: stream.window, visibility: stream.window == focused ? .focused : .visible, isIdle: stream.isIdle,
                pixelWidth: UInt32(clamping: size.width), pixelHeight: UInt32(clamping: size.height),
                requestedFramesPerSecond: stream.requestedFPS, requestedQuality: stream.quality)
        }
    }

    private func updateRate() async {
        guard !closed else { return }
        rate.setWindows(rateWindows())
        await apply(rate.evaluate())
    }

    private func ingest(_ stats: LinkStats) async {
        guard !streams.isEmpty else { return }
        let known = stats.windows.filter { streams[$0.window] != nil }
        rate.ingest(LinkStats(rttMicros: stats.rttMicros, windows: known))
        await apply(rate.evaluate())
    }

    private func apply(_ decision: RateDecision) async {
        for target in decision.targets {
            guard let stream = streams[target.window] else { continue }
            stream.target = target
            if target.isPaused {
                stream.paused = true
                continue
            }
            stream.paused = false
            if stream.appliedFPS != target.framesPerSecond {
                stream.appliedFPS = target.framesPerSecond
                var request = stream.request
                request.framesPerSecond = target.framesPerSecond
                await capture.update(window: target.window, request: request)
            }
            stream.encoder?.setTargets(bitrate: target.bitrate, framesPerSecond: target.framesPerSecond)
            if target.forceKeyFrame || target.refreshAtLowQP {
                var options = EncodeOptions()
                options.forceKeyFrame = target.forceKeyFrame
                options.forceLTRRefresh = target.refreshAtLowQP && !target.forceKeyFrame && stream.hasAck
                // A window that has stopped changing sends no more frames, so the refresh re-encodes the last one.
                await reencode(stream, options)
            }
        }
    }

    // MARK: Menus

    private func ownedApp(bundleID: String) -> WindowStream? {
        streams.values.sorted { $0.window < $1.window }.first { $0.bundleID == bundleID }
    }

    private func menuTree(_ bundleID: String) async {
        guard info.capabilities.contains(.menus), let owner = ownedApp(bundleID: bundleID) else { return }
        let items = (try? await resources.menus.tree(pid: owner.pid)) ?? []
        await send(.menuTree(bundleID: bundleID, items: items))
    }

    private func pressMenu(_ bundleID: String, path: [UInt16]) async {
        guard info.capabilities.contains(.menus), let owner = ownedApp(bundleID: bundleID) else { return }
        do {
            try await resources.menus.press(pid: owner.pid, path: path)
        } catch MenuReaderError.stalePath {
            // The menu changed under the iPad: give it the current tree instead of pressing something else.
            await resources.menus.invalidate(pid: owner.pid)
            if let items = try? await resources.menus.tree(pid: owner.pid) { await send(.menuTree(bundleID: bundleID, items: items)) }
        } catch {
            log.notice("menu press failed")
        }
    }

    // MARK: Clipboard

    private func handleClipboard(_ message: LinkMessage) async {
        guard !streams.isEmpty else { return }
        for reply in await clipboard.handle(message) { await send(reply) }
    }

    // MARK: Files

    private func fileBegin(_ begin: LinkFileBegin) async {
        guard info.capabilities.contains(.files), !streams.isEmpty, let inbox = resources.inbox,
              transfers.count < Self.maxOpenTransfers, transfers[begin.transfer] == nil else { return }
        // A file can only be opened by an app the iPad is streaming a window of.
        if let target = begin.targetBundleID, ownedApp(bundleID: target) == nil { return }
        let internalID = await host.allocateTransfer()
        var forwarded = begin
        forwarded.transfer = internalID
        do {
            try await inbox.begin(forwarded)
            transfers[begin.transfer] = internalID
        } catch {
            log.notice("file transfer refused")
        }
    }

    private func fileChunk(_ chunk: LinkFileChunk) async {
        guard let inbox = resources.inbox, let internalID = transfers[chunk.transfer] else { return }
        var forwarded = chunk
        forwarded.transfer = internalID
        do { try await inbox.append(forwarded) } catch { transfers[chunk.transfer] = nil }  // the inbox already aborted it
    }

    private func fileEnd(_ transfer: TransferID, sha256: LinkBytes32) async {
        guard let inbox = resources.inbox, let internalID = transfers.removeValue(forKey: transfer) else { return }
        do {
            let file = try await inbox.finish(transfer: internalID, sha256: sha256)
            if let target = file.targetBundleID, ownedApp(bundleID: target) != nil {
                try await inbox.open(transfer: internalID)
            }
        } catch {
            log.notice("file transfer failed")
        }
    }

    // MARK: Audio

    private func startAudio(pid: Int32) async {
        guard resources.options.audioEnabled, info.capabilities.contains(.audio), let audio = resources.audio,
              audioRuns[pid] == nil, audioRuns.count < 8, await host.claimAudio(pid: pid, session: id) else { return }
        guard var packetizer = try? AudioPacketizer(pid: pid, channels: audio.channels) else {
            await host.releaseAudio(pid: pid, session: id)
            return
        }
        let chunks: AsyncStream<PCMChunk>
        do { chunks = try await audio.capture.start(pid: pid, channels: audio.channels) } catch {
            await host.releaseAudio(pid: pid, session: id)
            return
        }
        guard await send(.audioConfig(packetizer.makeConfig(codec: audio.codec))) else {
            await audio.capture.stop(pid: pid)
            await host.releaseAudio(pid: pid, session: id)
            return
        }
        let connection = connection
        let encode = audio.encode
        audioRuns[pid] = AudioRun(task: Task {
            for await chunk in chunks {
                for packet in packetizer.append(chunk) {
                    guard let wire = encode(packet) else { continue }
                    try? await connection.send(.audioPacket(wire))
                }
            }
        })
    }

    private func stopAudio(pid: Int32) async {
        guard let run = audioRuns.removeValue(forKey: pid) else { return }
        run.task.cancel()
        await resources.audio?.capture.stop(pid: pid)
        await host.releaseAudio(pid: pid, session: id)
    }
}
#endif
