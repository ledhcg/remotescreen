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
    @ObservationIgnored private var lastResync: TimeInterval = 0
    @ObservationIgnored private var scenesWaitingForWindow: [SceneID: WindowID] = [:]
    @ObservationIgnored private var scenesReopening: Set<SceneID> = []

    init(
        computerID: UUID, policy: ReconnectPolicy = .standard, autoStart: Bool = true,
        resolveComputer: @escaping @MainActor () -> SavedConnection?
    ) {
        self.computerID = computerID
        self.policy = policy
        self.resolveComputer = resolveComputer
        keyframes = KeyframeRequester { [weak self] window in self?.sendNow(.streamKeyframe(window)) }
        if autoStart { start() }
    }

    nonisolated func close() {
        Task { @MainActor in self.shutdown() }
    }

    // MARK: Lifecycle

    func start() {
        guard runTask == nil else { return }
        phase = .connecting
        runTask = Task { [weak self] in await self?.runLoop() }
    }

    /// Ends the session: no more reconnects, streams stopped, the link closed politely.
    func shutdown() {
        runTask?.cancel()
        runTask = nil
        backoffTask?.cancel()
        let closing = link
        link = nil
        sender?.finish()
        sender = nil
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

    /// The app came back to the foreground: if a reconnect is waiting, do not wait any longer.
    func appDidBecomeActive() {
        if case .reconnecting = phase { backoffTask?.cancel() }
    }

    // MARK: Connect and run

    private func runLoop() async {
        var attempts = 0
        while !Task.isCancelled {
            do {
                let connection = try await connect()
                attempts = 0
                try await serve(connection)
            } catch is CancellationError {
                return
            } catch {
                if Task.isCancelled { return }
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
              let host = helperEndpoint.lastKnownHost, let port = helperEndpoint.lastKnownPort else {
            throw LinkSessionError.notAuthorized
        }
        let configuration = try LinkPairing.reconnectConfiguration(computerID: computerID, resume: credentials)
        return try await LinkConnection.connect(to: LinkEndpoint(host: host, port: port), configuration: configuration)
    }

    private func serve(_ connection: LinkConnection) async throws {
        link = connection
        let sender = LinkSender(link: connection)
        self.sender = sender
        credentials = LinkResumeCredentials(token: connection.session.resumeToken, lastStateVersion: 0)
        macName = connection.session.macName
        helper.reset()
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
        let pinger = Task { @MainActor [weak self] in await self?.pingLoop() }
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
        subscriptions.connectionLost()
        keyframes.reset()
    }

    private func pingLoop() async {
        while !Task.isCancelled {
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
        switch message {
        case .pong(let sent):
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
        case .snapshot, .windowCreated, .windowUpdated, .windowDestroyed, .windowOrder, .windowCapabilities, .appsChanged:
            applyWorkspace(message)
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
        if change.didChange { reconcileScenes() }
        if change.resync != nil { requestResync() }
    }

    private func handle(_ event: LinkEvent) {
        switch event {
        case .streamOpened(.window(let id), let inbox):
            // Only windows a scene asked for get a decoder; anything else is ignored.
            guard subscriptions.wanted.contains(id) || streams[id] != nil else { return }
            stream(for: id).attach(inbox)
        case .videoBackpressure(let window, _, let needsKeyframe):
            if needsKeyframe { keyframes.request(window) }
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

    private func reconcileScenes() {
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
        streams[window] = created
        return created
    }

    /// Asks the Mac to stream `window` at about `pixelSize` device pixels. Safe to call again when the size changes.
    func subscribe(window: WindowID, pixelSize: CGSize, maxFramesPerSecond: Int) {
        _ = stream(for: window)
        let subscription = LinkSubscribe(
            window: window, pixelWidth: Self.dimension(pixelSize.width), pixelHeight: Self.dimension(pixelSize.height),
            maxFramesPerSecond: UInt16(clamping: min(max(maxFramesPerSecond, 1), 120)), quality: .balanced
        )
        for command in subscriptions.subscribe(subscription) { perform(command) }
    }

    func unsubscribe(_ window: WindowID) {
        for command in subscriptions.unsubscribe(window) { perform(command) }
        keyframes.forget(window)
        statsBook.withLock { $0.forget(window: window) }
        streams.removeValue(forKey: window)?.shutdown()
        framesShown.remove(window)
    }

    /// The scene went to the background: stop the stream (the decoder's VideoToolbox session would not survive anyway).
    func pause(window: WindowID) {
        for command in subscriptions.pause(window) { perform(command) }
        streams[window]?.suspend()
    }

    /// The scene is active again: subscribe, then ask for a key frame (the decoder requests it through the rate limiter).
    func resume(window: WindowID) {
        for command in subscriptions.resume(window) { perform(command) }
        streams[window]?.resume()
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

    // MARK: Input and commands

    /// Sends input messages in order. Dropped while there is no connection.
    func sendInput(_ messages: [LinkMessage]) {
        guard let sender else { return }
        for message in messages { sender.send(message) }
    }

    func send(_ message: LinkMessage) { sender?.send(message) }

    var isConnected: Bool { phase == .connected }
}
