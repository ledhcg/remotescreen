import ConnectionKit
import Foundation
import InputKit
import LinkProtocol
import LinkTransport
import Observation
import RemoteDisplay
import SessionKit
import WindowKit
import os

/// None of the Mac's addresses can work on this network: they are all Tailscale addresses and Tailscale is off in Screon or not
/// connected on the device. Retrying cannot help until that changes; the network watch starts again when it does.
struct TailscaleUnavailable: Error {
    var turnedOff: Bool
    var failureKind: ConnectionFailureKind { turnedOff ? .tailscaleTurnedOff : .tailscaleNotConnected }
}

/// Lets `LinkSessionError` stop `ReconnectPolicy`: only the user can fix these (pair again, update an app, approve on the Mac).
struct LinkFailure: PermanentConnectionFailure {
    var error: LinkSessionError

    var permanentReason: ReconnectPolicy.GiveUpReason {
        if case .versionMismatch = error { return .incompatible }
        if case .peerClosed(let code) = error, code == .versionMismatch { return .incompatible }
        return .authenticationFailed
    }
}

extension LinkSessionError {
    /// What a window should say about this error.
    var failureKind: ConnectionFailureKind {
        switch self {
        case .versionMismatch(let result):
            switch result {
            case .remoteTooOld: return .versionMismatch(.helper)
            case .remoteTooNew: return .versionMismatch(.screon)
            case .agreed: return .connectionLost
            }
        case .notAuthorized: return .deviceRevoked
        case .pinMismatch: return .identityChanged
        case .pairingDenied, .approvalDenied, .sasRejected, .pairingFailed: return .denied
        case .sessionReplaced: return .replaced
        case .peerClosed(let code):
            if code == .versionMismatch { return .versionMismatch(.screon) }
            if code == .notAuthorized { return .deviceRevoked }
            if code == .approvalDenied { return .denied }
            if code == .sessionReplaced { return .replaced }
            return .connectionLost
        default: return .connectionLost
        }
    }
}

/// Sends messages to the Mac in the order they were queued, from any thread. Input, acknowledgements and requests all go through here, so
/// a key press never overtakes the pointer move before it.
final class LinkSender: @unchecked Sendable {
    private let continuation: AsyncStream<LinkMessage>.Continuation
    private let task: Task<Void, Never>

    init(link: LinkConnection) {
        let (stream, continuation) = AsyncStream.makeStream(of: LinkMessage.self)
        self.continuation = continuation
        task = Task.detached(priority: .userInitiated) {
            for await message in stream {
                // A full queue drops the message (stale pointer moves); a dead connection is noticed by the reader.
                try? await link.send(message)
            }
        }
    }

    func send(_ message: LinkMessage) { continuation.yield(message) }

    func finish() {
        continuation.finish()
        task.cancel()
    }
}

/// The App Mode session with one Mac, shared by all of its windows (see `LinkSessionRegistry`).
///
/// It connects (and reconnects with `ReconnectPolicy`, resuming the session), keeps the `RemoteWorkspace` current from the helper's
/// snapshot and deltas, subscribes the windows the scenes show, decodes their video off the main actor, and reports statistics and
/// pings so the helper can adapt and QUIC stays alive. Scenes read its state and send input through it.
@available(iOS 26, *)
@MainActor
@Observable
final class AppModeConnection: AppModeSession {
    static let statsInterval: Duration = .milliseconds(250)
    /// Well under QUIC's idle timeout (60 s).
    static let pingInterval: Duration = .seconds(15)
    /// A ping unanswered this long (and nothing else heard on the control stream) means the link is dead even if the transport
    /// has not noticed: QUIC waits for its 60 s idle timeout, and on TCP the outstanding pings keep keepalive from probing.
    static let deadLinkTimeout: Duration = pingInterval * 2 + .seconds(5)
    static let minResyncGap: TimeInterval = 2

    let computerID: UUID

    // MARK: State for the views

    private(set) var phase: ConnectionPhase = .connecting
    private(set) var workspace = RemoteWorkspace()
    private(set) var helper = HelperStatus()
    private(set) var macName: String?
    private(set) var bindings = SceneBindings()
    /// Windows that have shown a picture since their stream was (re)started.
    private(set) var framesShown: Set<WindowID> = []
    /// Round trip time of the last ping, in milliseconds.
    private(set) var roundTripMillis: Double?
    /// Lists of apps for the launcher (`apps.list`).
    private(set) var directory = AppsDirectory()
    /// New Mac windows: badges per app, and windows waiting to get a scene.
    private(set) var newWindows = NewWindowInbox()
    /// Bumped whenever a menu tree changed, so menus can be rebuilt.
    private(set) var menuRevision = 0

    // MARK: Internals

    @ObservationIgnored private let resolveComputer: @MainActor () -> SavedConnection?
    @ObservationIgnored private let policy: ReconnectPolicy
    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored private var backoffTask: Task<Void, Never>?
    @ObservationIgnored private var link: LinkConnection?
    @ObservationIgnored private var sender: LinkSender?
    @ObservationIgnored private var credentials: LinkResumeCredentials?
    @ObservationIgnored private var hasConnectedOnce = false
    @ObservationIgnored private var subscriptions = SubscriptionManager()
    @ObservationIgnored private var streams: [WindowID: WindowStream] = [:]
    @ObservationIgnored private let statsBook = OSAllocatedUnfairLock(initialState: ConnectionStatsBook())
    @ObservationIgnored private var keyframes: KeyframeRequester!
    @ObservationIgnored private var rttMicros: UInt32 = 0
    /// When the oldest ping still unanswered was sent; any control message from the Mac clears it.
    @ObservationIgnored private var unansweredPingSince: ContinuousClock.Instant?
    @ObservationIgnored private var lastResync: TimeInterval = 0
    /// Follows the device's network (`NetworkRecovery`) while the session runs.
    @ObservationIgnored private var networkWatch: NetworkWatch?
    /// The address the live link was made to, to know whether it goes through Tailscale.
    @ObservationIgnored private var connectedHost: String?
    /// Clipboard and file transfers, shared by this connection's windows (reached through `WindowStream.services`).
    @ObservationIgnored let services = AppWindowServices()
    @ObservationIgnored private var audio: AppAudioPlayer?
    @ObservationIgnored private var barriers: [UInt64: CheckedContinuation<Bool, Never>] = [:]
    @ObservationIgnored private var nextBarrier: UInt64 = 1 << 62
    @ObservationIgnored private var scenesWaitingForWindow: [SceneID: WindowID] = [:]
    @ObservationIgnored private var scenesReopening: Set<SceneID> = []
    @ObservationIgnored private var scenesStarting: [SceneID: WindowRef] = [:]
    @ObservationIgnored private var revalidateOnSnapshot = false
    @ObservationIgnored private var expectingLaunch: Set<String> = []
    @ObservationIgnored private(set) var menuTrees = MenuTreeCache()
    @ObservationIgnored private(set) var icons: AppIconStore!

    init(
        computerID: UUID, policy: ReconnectPolicy = .standard, autoStart: Bool = true,
        resolveComputer: @escaping @MainActor () -> SavedConnection?
    ) {
        self.computerID = computerID
        self.policy = policy
        self.resolveComputer = resolveComputer
        keyframes = KeyframeRequester { [weak self] window in self?.sendNow(.streamKeyframe(window)) }
        services.bundleID = { [weak self] window in self?.workspace.window(window)?.bundleID }
        services.files.isConnected = { [weak self] in self?.isConnected ?? false }
        services.files.transport = { [weak self] message in await self?.sendReliably(message) ?? .failed }
        services.files.barrier = { [weak self] in await self?.barrier() ?? false }
        icons = AppIconStore(computerID: computerID) { [weak self] message in self?.send(message) }
        if autoStart { start() }
    }

    nonisolated func close() {
        Task { @MainActor in self.shutdown() }
    }

    // MARK: Lifecycle

    func start() {
        guard runTask == nil else { return }
        phase = .connecting
        if networkWatch == nil {
            networkWatch = NetworkWatch { [weak self] before, after, outage in
                self?.networkChanged(before: before, after: after, outage: outage)
            }
        }
        runTask = Task { [weak self] in await self?.runLoop() }
    }

    /// Ends the session: no more reconnects, streams stopped, the link closed politely.
    func shutdown() {
        runTask?.cancel()
        runTask = nil
        networkWatch?.stop()
        networkWatch = nil
        backoffTask?.cancel()
        let closing = link
        link = nil
        sender?.finish()
        sender = nil
        services.sessionEnded()
        audio?.shutdown()
        audio = nil
        failBarriers()
        for stream in streams.values { stream.shutdown() }
        streams.removeAll()
        keyframes.reset()
        subscriptions.reset()
        if let closing { Task { await closing.close() } }
    }

    /// Try now instead of waiting for the next scheduled attempt, or start again after a permanent failure (for example "Try again").
    func retry() {
        if runTask == nil || isFinished {
            runTask = nil
            start()
        } else {
            backoffTask?.cancel()
        }
    }

    private var isFinished: Bool {
        if case .failed = phase { return true }
        return false
    }

    /// The network changed under the session (see `NetworkRecovery`). A failure only Tailscale can fix is retried as soon as it is usable.
    private func networkChanged(before: NetworkSnapshot, after: NetworkSnapshot, outage: Duration?) {
        if case .failed(let kind) = phase, kind == .tailscaleNotConnected || kind == .tailscaleTurnedOff {
            if after.isOnline, after.usesTailscale, NetworkPreferences.useTailscale { retry() }
            return
        }
        let session: NetworkRecovery.Session = switch phase {
        case .connected: .live
        case .reconnecting: .waitingToRetry
        case .connecting, .waitingForNetwork, .failed: .inactive
        }
        let viaTailscale = connectedHost.map(TailscaleNetwork.isTailscaleHost) ?? false
        switch NetworkRecovery.action(before: before, after: after, outage: outage, session: session, viaTailscale: viaTailscale) {
        case .none: break
        case .retryNow: backoffTask?.cancel()
        case .reconnect:
            // Closing ends the control stream: `serve` returns and the run loop reconnects over the new network.
            if let link { Task { await link.close(code: .normal, reason: "network changed") } }
        }
    }

    /// The app came back to the foreground: if a reconnect is waiting, do not wait any longer.
    func appDidBecomeActive() {
        switch phase {
        case .reconnecting: backoffTask?.cancel()
        case .connected:
            // The link may have died while the app was away (Wi-Fi change, the Mac slept): probe now, so the dead-link check
            // starts counting at once instead of at the next ping.
            unansweredPingSince = .now
            sendNow(.ping(timestampMicros: Self.nowMicros))
        default: break
        }
    }

    // MARK: Connect and run

    private func runLoop() async {
        var attempts = 0
        while !Task.isCancelled {
            if let networkWatch, !networkWatch.isOnline {
                // No network: an attempt can only fail and use up the allowance. Wait, then try at once.
                phase = .waitingForNetwork
                await networkWatch.waitUntilOnline()
                if Task.isCancelled { return }
                phase = hasConnectedOnce ? .reconnecting(attempt: max(attempts, 1), total: policy.maxAttempts) : .connecting
            }
            do {
                let connection = try await connect()
                // `shutdown()` while the connect was in flight: a session started now would run on with nobody to stop it,
                // and could replace the session of a newer connection to the same Mac.
                if Task.isCancelled {
                    await connection.close()
                    return
                }
                attempts = 0
                try await serve(connection)
            } catch is CancellationError {
                return
            } catch let unavailable as TailscaleUnavailable {
                phase = .failed(unavailable.failureKind)
                teardownConnection()
                runTask = nil
                return
            } catch {
                if Task.isCancelled { return }
                if let networkWatch, !networkWatch.isOnline { continue } // the loop waits for the network, without counting an attempt
                let sessionError = (error as? LinkSessionError) ?? .transport("lost")
                let reported: Error = sessionError.isPermanent ? LinkFailure(error: sessionError) : sessionError
                switch policy.decision(after: reported, attemptsMade: attempts) {
                case .giveUp(let reason):
                    phase = .failed(reason == .attemptsExhausted ? .connectionLost : sessionError.failureKind)
                    teardownConnection()
                    runTask = nil
                    return
                case .retry(let delay, let attempt):
                    attempts = attempt
                    phase = hasConnectedOnce ? .reconnecting(attempt: attempt, total: policy.maxAttempts) : .connecting
                    await backoff(delay)
                }
            }
        }
    }

    private func backoff(_ delay: Duration) async {
        let task = Task<Void, Never> { _ = try? await Task.sleep(for: delay) }
        backoffTask = task
        await task.value
        backoffTask = nil
    }

    private func connect() async throws -> LinkConnection {
        guard let computer = resolveComputer(), let helperEndpoint = computer.helper,
              let port = helperEndpoint.lastKnownPort, !helperEndpoint.candidateHosts.isEmpty else {
            throw LinkSessionError.notAuthorized
        }
        let configuration = try LinkPairing.reconnectConfiguration(computerID: computerID, resume: credentials, settings: settings)
        // The address that worked last first, then the others the helper offered (home LAN, `.local`, Tailscale…): away from
        // home only the VPN address answers. The pin is the same for all of them, so a wrong host cannot impersonate the Mac.
        let useTailscale = NetworkPreferences.useTailscale
        let hosts = HostOrdering.order(helperEndpoint.candidateHosts, network: NetworkMonitor.shared.snapshot, useTailscale: useTailscale)
        guard !hosts.isEmpty else { throw TailscaleUnavailable(turnedOff: !useTailscale) }
        var lastError: Error = LinkSessionError.transport("no address")
        for host in hosts {
            do {
                let connection = try await LinkConnection.connect(to: LinkEndpoint(host: host, port: port), configuration: configuration)
                connectedHost = host
                return connection
            } catch let error as LinkSessionError where error.isPermanent {
                throw error  // revoked, pin mismatch, version: another address will not change that
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    private func serve(_ connection: LinkConnection) async throws {
        link = connection
        let sender = LinkSender(link: connection)
        self.sender = sender
        credentials = LinkResumeCredentials(token: connection.session.resumeToken, lastStateVersion: 0)
        macName = connection.session.macName
        helper.reset()
        services.sessionStarted(capabilities: connection.session.capabilities) { [weak self] message in self?.send(message) }
        if connection.session.capabilities.contains(.audio), settings.playAudio, audio == nil { audio = AppAudioPlayer() }
        directory.connectionLost()
        icons.connectionLost()
        menuTrees.reset()
        revalidateOnSnapshot = true
        hasConnectedOnce = true
        phase = .connected
        for command in subscriptions.connectionEstablished() { perform(command) }

        let control = connection.controlMessages
        let events = connection.events
        let reader = Task { @MainActor [weak self] in
            for await message in control { self?.handle(message) }
        }
        let eventReader = Task { @MainActor [weak self] in
            for await event in events { self?.handle(event) }
        }
        let pinger = Task { @MainActor [weak self] in await self?.pingLoop(connection) }
        let reporter = Task { @MainActor [weak self] in await self?.statsLoop() }
        // The control stream ending means the connection is gone; stop the helpers that would run forever.
        await withTaskCancellationHandler {
            await reader.value
        } onCancel: {
            reader.cancel()
        }
        eventReader.cancel()
        pinger.cancel()
        reporter.cancel()
        let failure = await connection.failure
        teardownConnection()
        throw failure ?? LinkSessionError.transport("connection lost")
    }

    /// The link is gone (or the session ended): forget what the helper held for us. Windows keep their last picture.
    private func teardownConnection() {
        sender?.finish()
        sender = nil
        link = nil
        connectedHost = nil
        services.sessionEnded()
        audio?.shutdown()
        audio = nil
        failBarriers()
        subscriptions.connectionLost()
        keyframes.reset()
    }

    private func pingLoop(_ connection: LinkConnection) async {
        unansweredPingSince = nil
        var previousTick = ContinuousClock.now
        while !Task.isCancelled {
            let now = ContinuousClock.now
            // A tick far later than scheduled means the app was suspended: what went unanswered meanwhile says nothing.
            if now - previousTick > Self.pingInterval * 2 {
                unansweredPingSince = nil
            } else if let since = unansweredPingSince, now - since > Self.deadLinkTimeout {
                // Closing ends the control stream, so `serve` returns and the run loop reconnects.
                await connection.close(code: .normal, reason: "no answer")
                return
            }
            previousTick = now
            if unansweredPingSince == nil { unansweredPingSince = now }
            sendNow(.ping(timestampMicros: Self.nowMicros))
            try? await Task.sleep(for: Self.pingInterval)
        }
    }

    private func statsLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: Self.statsInterval)
            var counters: [WindowID: DecoderCounters] = [:]
            for id in subscriptions.streaming {
                if let stream = streams[id] { counters[id] = stream.counters() }
            }
            let rtt = rttMicros, report = counters
            if let stats = statsBook.withLock({ $0.makeStats(rttMicros: rtt, counters: report) }) { sendNow(.stats(stats)) }
        }
    }

    private static var nowMicros: UInt64 { DispatchTime.now().uptimeNanoseconds / 1000 }

    nonisolated private func sendNow(_ message: LinkMessage) {
        Task { @MainActor in self.sender?.send(message) }
    }

    // MARK: Messages from the Mac

    private func handle(_ message: LinkMessage) {
        unansweredPingSince = nil // the Mac is answering
        switch message {
        case .pong(let sent):
            if let waiting = barriers.removeValue(forKey: sent) { waiting.resume(returning: true); return }
            let now = Self.nowMicros
            if now >= sent {
                rttMicros = UInt32(clamping: now - sent)
                roundTripMillis = Double(rttMicros) / 1000
            }
        case .status(let status):
            helper.apply(status)
        case .windowSubscribeFailed(let window, let reason):
            // Only for a window a scene asked for: a helper cannot fill the table with windows nobody shows.
            if subscriptions.wanted.contains(window) { helper.noteSubscribeFailure(window: window, reason: reason) }
        case .clipboardOffer, .clipboardRequest, .clipboardData:
            services.receive(clipboard: message)
        case .snapshot, .windowCreated, .windowUpdated, .windowDestroyed, .windowOrder, .windowCapabilities, .appsChanged:
            applyWorkspace(message)
            refreshAudioMute()
        case .appsItems(let items):
            directory.receive(items)
        case .appsIconData(let key, let png):
            icons.receive(key: key, png: png)
        case .menuTree(let bundleID, let items):
            if menuTrees.receive(bundleID: bundleID, items: items, at: Self.now) { menuRevision += 1 }
        default:
            break
        }
    }

    private func applyWorkspace(_ message: LinkMessage) {
        if case .windowDestroyed(let id) = message { forgetWindow(id) }
        let change = workspace.apply(message)
        if case .snapshot = message {
            for id in streams.keys where workspace.window(id) == nil { forgetWindow(id) }
        }
        if case .snapshot = message, revalidateOnSnapshot, workspace.hasSnapshot {
            // A new connection: window ids may belong to another helper run, and nothing on the Mac is "new".
            revalidateOnSnapshot = false
            bindings.revalidate(with: workspace)
            newWindows.rebaseline(workspace)
        }
        if change.didChange {
            reconcileScenes()
            updateNewWindows()
        }
        if change.resync != nil { requestResync() }
    }

    private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    private func handle(_ event: LinkEvent) {
        switch event {
        case .streamOpened(.window(let id), let inbox):
            // Only windows a scene asked for get a decoder. Anything else is still read to its end and dropped: an inbox nobody
            // reads fills up, and on the TCP fallback a full inbox stalls the one reader that every stream shares.
            guard subscriptions.wanted.contains(id) || streams[id] != nil else {
                Task.detached { for await _ in inbox {} }
                return
            }
            stream(for: id).attach(inbox)
        case .videoBackpressure(let window, _, let needsKeyframe):
            if needsKeyframe { keyframes.request(window) }
        case .streamOpened(.audio, let inbox):
            audio?.attach(inbox)
            refreshAudioMute()
        case .streamOpened, .streamFinished, .closed:
            break
        }
    }

    /// The model cannot be trusted any more: the quickest repair is a reconnect, which brings a full snapshot.
    private func requestResync() {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastResync >= Self.minResyncGap, let link else { return }
        lastResync = now
        Task { await link.close(code: .normal, reason: "resync") }
    }

    private func forgetWindow(_ id: WindowID) {
        subscriptions.windowDestroyed(id)
        keyframes.forget(id)
        statsBook.withLock { $0.forget(window: id) }
        streams.removeValue(forKey: id)?.shutdown()
        framesShown.remove(id)
        helper.clearSubscribeFailure(window: id)
        // Menus and popovers of other windows live in their parent's stream.
        for stream in streams.values { stream.removeSurface(SurfaceID(rawValue: id.rawValue)) }
    }

    // MARK: Scenes

    func bindingState(of scene: SceneID) -> SceneBindingState? { bindings.state(of: scene) }

    /// A scene wants to show `window`. Waits for the snapshot when it has not arrived yet.
    func attach(scene: SceneID, window: WindowID) {
        scenesWaitingForWindow[scene] = window
        reconcileScenes()
    }

    /// The scene is gone: stop its stream.
    func detach(scene: SceneID) {
        scenesStarting[scene] = nil
        if let window = bindings.state(of: scene)?.windowID ?? scenesWaitingForWindow[scene] { unsubscribe(window) }
        scenesWaitingForWindow[scene] = nil
        scenesReopening.remove(scene)
        bindings.remove(scene: scene)
    }

    /// "Reopen": activate (or launch) the window's app and bind to the next matching window.
    func reopen(scene: SceneID) {
        guard case .windowClosed(let hint)? = bindings.state(of: scene) else { return }
        scenesReopening.insert(scene)
        sendNow(workspace.app(bundleID: hint.bundleID) == nil ? .appsLaunch(bundleID: hint.bundleID) : .appsActivate(bundleID: hint.bundleID))
        reconcileScenes()
    }

    /// A scene starts from a stored reference (a restored scene, or one opened from the launcher): the live id when it still fits,
    /// otherwise the best window for the saved hint.
    func attach(scene: SceneID, ref: WindowRef) {
        scenesStarting[scene] = ref
        reconcileScenes()
    }

    /// Shows `window` in `scene` instead of what it showed (tabs, and the iPhone's window switcher). A window that another scene
    /// already shows is not taken over: the answer says which scene to bring forward.
    @discardableResult
    func switchScene(_ scene: SceneID, to window: WindowID) -> OpenWindowResult {
        let result = bindings.open(window: window, in: scene, workspace: workspace)
        scenesWaitingForWindow[scene] = nil
        return result
    }

    private func reconcileScenes() {
        for (scene, ref) in scenesStarting where workspace.hasSnapshot {
            scenesStarting[scene] = nil
            let others = Set(bindings.scenes.filter { $0 != scene }.compactMap { bindings.state(of: $0)?.windowID })
            switch ref.start(in: workspace, excluding: others) {
            case .bind(let id):
                if case .focusExisting = bindings.open(window: id, in: scene, workspace: workspace), let query = ref.query {
                    bindings.restore(scene: scene, query: query, workspace: workspace)
                }
            case .search(let query):
                bindings.restore(scene: scene, query: query, workspace: workspace)
            case .nothing:
                bindings.restore(scene: scene, query: WindowMatchQuery(bundleID: "", title: "", indexHint: 0), workspace: workspace)
            }
        }
        for (scene, window) in scenesWaitingForWindow {
            guard workspace.hasSnapshot else { continue }
            scenesWaitingForWindow[scene] = nil
            if workspace.window(window)?.isManaged == true {
                if case .focusExisting = bindings.open(window: window, in: scene, workspace: workspace) {
                    bindings.restore(scene: scene, query: WindowMatchQuery(bundleID: "", title: "", indexHint: 0), workspace: workspace)
                }
            } else {
                bindings.restore(scene: scene, query: WindowMatchQuery(bundleID: "", title: "", indexHint: 0), workspace: workspace)
            }
        }
        bindings.reconcile(with: workspace)
        for scene in scenesReopening where bindings.rebind(scene: scene, workspace: workspace) { scenesReopening.remove(scene) }
    }

    // MARK: Streams and subscriptions

    /// The stream of a window, created on first use so a scene can attach before the Mac opens it.
    func stream(for window: WindowID) -> WindowStream {
        if let existing = streams[window] { return existing }
        let requester: KeyframeRequester = keyframes
        let created = WindowStream(
            window: window, statsBook: statsBook,
            send: { [weak self] message in self?.sendNow(message) },
            requestKeyframe: { id in requester.request(id) },
            onFirstFrame: { [weak self] id in
                Task { @MainActor in
                    self?.framesShown.insert(id)
                    self?.helper.clearSubscribeFailure(window: id)
                }
            }
        )
        created.services = services
        streams[window] = created
        return created
    }

    /// Asks the Mac to stream `window` at about `pixelSize` device pixels. Safe to call again when the size changes.
    func subscribe(window: WindowID, pixelSize: CGSize, maxFramesPerSecond: Int) {
        _ = stream(for: window)
        let settings = self.settings
        let subscription = LinkSubscribe(
            window: window, pixelWidth: Self.dimension(pixelSize.width), pixelHeight: Self.dimension(pixelSize.height),
            maxFramesPerSecond: UInt16(clamping: settings.effectiveFramesPerSecond(displayMaximum: maxFramesPerSecond)),
            quality: Self.tier(for: settings.qualityCap)
        )
        for command in subscriptions.subscribe(subscription) { perform(command) }
        refreshAudioMute()
    }

    func unsubscribe(_ window: WindowID) {
        for command in subscriptions.unsubscribe(window) { perform(command) }
        defer { refreshAudioMute() }
        keyframes.forget(window)
        statsBook.withLock { $0.forget(window: window) }
        streams.removeValue(forKey: window)?.shutdown()
        framesShown.remove(window)
    }

    /// The scene went to the background: stop the stream (the decoder's VideoToolbox session would not survive anyway).
    func pause(window: WindowID) {
        for command in subscriptions.pause(window) { perform(command) }
        streams[window]?.suspend()
        refreshAudioMute()
    }

    /// The scene is active again: subscribe, then ask for a key frame (the decoder requests it through the rate limiter).
    func resume(window: WindowID) {
        for command in subscriptions.resume(window) { perform(command) }
        streams[window]?.resume()
        refreshAudioMute()
    }

    private func perform(_ command: SubscriptionCommand) {
        switch command {
        case .subscribe(let subscription): sendNow(.windowSubscribe(subscription))
        case .unsubscribe(let window): sendNow(.windowUnsubscribe(window))
        }
    }

    /// A pixel count the protocol accepts: at least 1, at most the limits this device announced.
    private static func dimension(_ value: CGFloat) -> UInt32 {
        guard value.isFinite, value >= 1 else { return 1 }
        return UInt32(min(Double(value.rounded()), 4096))
    }

    // MARK: Settings, audio and flow control

    /// The person's streaming choices for this computer, read when they are used (a change applies to the next subscription).
    private var settings: AppModeSettings { resolveComputer()?.appModeSettings ?? .standard }

    private static func tier(for cap: AppModeSettings.QualityCap) -> LinkQualityTier {
        switch cap {
        case .low: .low
        case .balanced: .balanced
        case .high: .high
        }
    }

    /// An app's sound plays only while one of its windows is on screen in a foreground scene.
    private func refreshAudioMute() {
        guard let audio else { return }
        let pids = audio.pids
        let muted = AudioMutePolicy.mutedPIDs(pids: pids, workspace: workspace, subscriptions: subscriptions)
        for pid in pids { audio.setMuted(muted.contains(pid), pid: pid) }
    }

    /// What the playback glitch counters say, for diagnostics.
    var audioStats: AudioPlayoutStats { audio?.stats ?? AudioPlayoutStats() }

    /// Sends on the control stream and says whether the queue took it, for file transfers (they must not drop a chunk).
    nonisolated func sendReliably(_ message: LinkMessage) async -> FileSendResult {
        guard let link = await MainActor.run(body: { self.link }) else { return .failed }
        do {
            try await link.send(message)
            return .sent
        } catch LinkQueueError.queueFull {
            return .busy
        } catch {
            return .failed
        }
    }

    /// Returns when the Mac has read everything sent on the control stream before this call (a ping answered in order), `false` after
    /// 10 seconds or when the connection ends.
    nonisolated func barrier() async -> Bool {
        let (id, link) = await MainActor.run { () -> (UInt64, LinkConnection?) in
            self.nextBarrier &+= 1
            return (self.nextBarrier, self.link)
        }
        guard let link else { return false }
        let answered: Bool = await withCheckedContinuation { continuation in
            Task { @MainActor in
                self.barriers[id] = continuation
                do {
                    try await link.send(.ping(timestampMicros: id))
                } catch {
                    if let waiting = self.barriers.removeValue(forKey: id) { waiting.resume(returning: false) }
                    return
                }
                try? await Task.sleep(for: .seconds(10))
                if let waiting = self.barriers.removeValue(forKey: id) { waiting.resume(returning: false) }
            }
        }
        return answered
    }

    private func failBarriers() {
        let waiting = barriers
        barriers = [:]
        for continuation in waiting.values { continuation.resume(returning: false) }
    }

    // MARK: Input and commands

    /// Sends input messages in order. Dropped while there is no connection.
    func sendInput(_ messages: [LinkMessage]) {
        guard let sender else { return }
        for message in messages { sender.send(message) }
    }

    func send(_ message: LinkMessage) { sender?.send(message) }

    var isConnected: Bool { phase == .connected }

    // MARK: Launcher, menus and window commands

    /// Asks for a list of apps once; the answer arrives in `directory`.
    func requestApps(_ filter: LinkAppFilter, force: Bool = false) {
        if force || !directory.hasLoaded(filter), directory.willRequest(filter) { send(.appsList(filter: filter)) }
    }

    /// Bundle ids of the apps that have a scene open.
    var sceneApps: Set<String> {
        Set(bindings.scenes.compactMap { bindings.state(of: $0)?.windowID }.compactMap { workspace.window($0)?.bundleID })
    }

    /// What tapping an app should do. Launching or activating is done here; the caller opens the windows of the plan.
    func openApp(bundleID: String, style: AppOpenStyle, canOpenSeveralScenes: Bool) -> AppOpenPlan {
        let plan = AppOpenPlan.make(
            bundleID: bundleID, workspace: workspace, bindings: bindings, style: style, canOpenSeveralScenes: canOpenSeveralScenes)
        newWindows.clearBadge(bundleID: bundleID)
        switch plan.start {
        case .launch:
            expect(bundleID)
            send(.appsLaunch(bundleID: bundleID))
        case .activateAndWait:
            expect(bundleID)
            send(.appsActivate(bundleID: bundleID))
        case .showWindows:
            send(.appsActivate(bundleID: bundleID))
        }
        return plan
    }

    func quitApp(bundleID: String) { send(.appsQuit(bundleID: bundleID)) }

    /// The app's first new window gets a scene even though it had none (it was just launched). Forgotten after 20 seconds.
    private func expect(_ bundleID: String) {
        expectingLaunch.insert(bundleID)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            self?.expectingLaunch.remove(bundleID)
        }
        updateNewWindows()
    }

    private func updateNewWindows() {
        let bound = Set(bindings.scenes.compactMap { bindings.state(of: $0)?.windowID })
        // With tabs a new window joins the app's tab bar; only a launched app's first window needs a scene.
        // iPhone has one scene: switching it to a new Mac window would take away the window being used (and a short-lived
        // one, such as a sheet that closes, left "This window was closed on the Mac"). There new windows only get a badge.
        let policy: NewWindowPolicy = AppModePreferences.openStyle == .tabs || !AppModeOpener.canOpenSeveralScenes
            ? .badge : AppModePreferences.newWindowPolicy
        let fulfilled = newWindows.update(workspace: workspace, policy: policy, sceneApps: sceneApps, expecting: expectingLaunch, bound: bound)
        expectingLaunch.subtract(fulfilled)
    }

    /// Windows that should get a scene now. Whoever takes them opens the scenes, so each is opened once.
    func takeWindowsToOpen() -> [WindowID] { newWindows.takeToOpen() }

    /// Fetches the menu of an app unless a recent tree is cached.
    func requestMenu(bundleID: String, force: Bool = false) {
        if menuTrees.shouldRequest(bundleID: bundleID, at: Self.now, force: force) { send(.menuGet(bundleID: bundleID)) }
    }

    func menuEntries(bundleID: String) -> [RemoteMenuEntry] { menuTrees.entry(for: bundleID)?.entries ?? [] }

    func pressMenu(bundleID: String, path: [UInt16]) { send(.menuPress(bundleID: bundleID, path: path)) }

    func command(_ command: LinkWindowCommand, on window: WindowID) { send(.windowCommand(window: window, command: command)) }

    func setFrame(window: WindowID, size: LinkSize) {
        send(.windowSetFrame(LinkSetFrame(window: window, size: size, placement: .keep)))
    }
}
