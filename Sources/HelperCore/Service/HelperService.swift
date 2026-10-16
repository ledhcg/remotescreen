#if os(macOS)
import Foundation
import LinkProtocol
import os

public enum HelperServiceError: Error, Equatable {
    case listenerFailed(String)
}

/// The Mac helper's orchestration (plan M3 H12): starts the listener, the window tracker, the app catalog and the stage,
/// runs one `HelperSession` per connected iPad, and publishes `HelperStatus` for the menu bar UI.
///
/// ```swift
/// let service = HelperService(dependencies: try .live(listener: listener))
/// try await service.start()
/// for await status in await service.statusUpdates() { render(status) }
/// ```
///
/// One instance runs once: create a new service (and listener) to start again after `stop()`.
public actor HelperService {
    private final class Relay: @unchecked Sendable {
        private let lock = NSLock()
        private var _injector: (@Sendable (InputInjectorEvent) -> Void)?
        private var _stage: (@Sendable (LinkStageState) -> Void)?
        func setInjector(_ handler: @escaping @Sendable (InputInjectorEvent) -> Void) { lock.withLock { _injector = handler } }
        func setStage(_ handler: @escaping @Sendable (LinkStageState) -> Void) { lock.withLock { _stage = handler } }
        func injector(_ event: InputInjectorEvent) { lock.withLock { _injector }?(event) }
        func stage(_ state: LinkStageState) { lock.withLock { _stage }?(state) }
    }

    private struct Entry {
        var session: HelperSession
        var task: Task<Void, Never>
        var info: HelperConnectionInfo
    }

    private let dependencies: HelperDependencies
    private let options: HelperServiceOptions
    private let hub = HelperStatusHub()
    private let relay = Relay()
    private let tracker: WindowTracker
    private let catalog: AppCatalog
    private let injector: InputInjector
    private let stage: Stage
    private let menus: MenuReader
    private let inputGate = AsyncGate()
    private let log = Logger(subsystem: "app.screon.helper", category: "service")

    private var inbox: FileInbox?
    private var sessions: [UInt64: Entry] = [:]
    private var windowRefs: [WindowID: Set<UInt64>] = [:]
    private var audioOwners: [Int32: UInt64] = [:]
    private var nextTransfer: UInt32 = 1
    private var stageRunning = false
    private var stageChain: Task<Void, Never>?
    private var backgroundTasks: [Task<Void, Never>] = []
    private var started = false
    private var stopping = false

    public init(dependencies: HelperDependencies, options: HelperServiceOptions = HelperServiceOptions()) {
        self.dependencies = dependencies
        self.options = options
        let relay = self.relay
        tracker = WindowTracker(system: dependencies.windowSystem)
        catalog = AppCatalog(workspace: dependencies.workspace, installed: dependencies.installedApps, recentsURL: dependencies.recentAppsURL)
        menus = MenuReader(system: dependencies.menuSystem)
        injector = InputInjector(
            poster: dependencies.eventPoster, geometry: TrackerWindowGeometry(tracker: tracker),
            focuser: TrackerWindowFocuser(tracker: tracker, system: dependencies.windowSystem, workspace: dependencies.workspace),
            secureInput: dependencies.secureInput, onEvent: { relay.injector($0) })
        stage = Stage(
            display: dependencies.displayStage, frames: TrackerFrameSetter(tracker: tracker), journal: dependencies.stageJournal,
            onState: { relay.stage($0) })
        let hub = self.hub
        relay.setInjector { [weak self] event in
            Task { await self?.injectorEvent(event) }
        }
        relay.setStage { [weak self] state in
            hub.update { $0.stage = state }
            Task { await self?.stageChanged(state) }
        }
    }

    // MARK: Status

    /// The current status.
    public var status: HelperStatus { hub.current }

    /// The current status first, then every change (the newest wins when the consumer is slow).
    public func statusUpdates() -> AsyncStream<HelperStatus> { hub.updates() }

    // MARK: Lifecycle

    /// Starts the tracker, the app catalog, the stage recovery, the inbox cleanup and the listener.
    public func start() async throws {
        guard !started else { return }
        started = true
        hub.update { $0.phase = .starting }

        await tracker.start()
        _ = await catalog.apps(filter: .running)  // warms the running-app table before the first change event
        await stage.recoverFromCrash()
        do {
            let created = try FileInbox(root: dependencies.inboxRoot, opener: dependencies.fileOpener)
            await created.cleanup()
            inbox = created
        } catch {
            log.error("file inbox unavailable: \(String(describing: error), privacy: .public)")
        }
        let permissions = currentPermissions()
        hub.update {
            $0.accessibility = permissions.accessibility
            $0.screenRecording = permissions.screenRecording
            $0.macLocked = dependencies.lockMonitor.isLocked
        }

        let port: UInt16
        do {
            port = try await dependencies.listener.start()
        } catch {
            let reason = String(describing: error)
            hub.update { $0.phase = .failed(reason) }
            await tracker.stop()
            started = false
            throw HelperServiceError.listenerFailed(reason)
        }
        hub.update { $0.phase = .running; $0.listeningPort = port }

        let connections = dependencies.listener.connections
        backgroundTasks.append(Task { [weak self] in
            for await connection in connections { await self?.accept(connection) }
        })
        backgroundTasks.append(Task { [weak self, interval = options.permissionPollInterval] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else { return }
                await self?.refreshPermissions()
            }
        })
        backgroundTasks.append(Task { [weak self, interval = options.secureInputPollInterval] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else { return }
                await self?.pollSecureInput()
            }
        })
        backgroundTasks.append(Task { [weak self, interval = options.inboxCleanupInterval] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else { return }
                await self?.cleanInbox()
            }
        })
        let lockChanges = dependencies.lockMonitor.changes()
        backgroundTasks.append(Task { [weak self] in
            for await locked in lockChanges { await self?.lockChanged(locked) }
        })
    }

    /// Closes every session, puts every window back, releases input and stops listening.
    public func stop() async {
        guard started, !stopping else { return }
        stopping = true
        for task in backgroundTasks { task.cancel() }
        backgroundTasks = []
        await dependencies.listener.stop()
        let entries = Array(sessions.values)
        sessions = [:]
        for entry in entries { await entry.session.shutdown(closing: .helperShuttingDown) }
        for entry in entries { entry.task.cancel() }
        windowRefs = [:]
        audioOwners = [:]
        await injector.setAuthorizedWindows([])
        await injector.releaseAll()
        await endStageIfIdle()
        await tracker.stop()
        dependencies.awake.release()
        hub.update {
            $0.phase = .stopped; $0.listeningPort = nil; $0.sessions = []; $0.secureInput = false
        }
        started = false
        stopping = false
    }

    /// Closes all sessions but keeps listening (the "Disconnect all" menu item).
    public func disconnectAll() async {
        for entry in Array(sessions.values) { await entry.session.shutdown(closing: .normal) }
    }

    /// Closes one session (for example after the device was revoked).
    public func disconnect(sessionID: UInt64, code: LinkCloseCode = .normal) async {
        await sessions[sessionID]?.session.shutdown(closing: code)
    }

    /// Puts every window the stage moved or resized back, now ("Restore windows" menu item).
    public func restoreWindows() async { await stage.restoreAll() }

    // MARK: Accepting sessions

    private func accept(_ connection: any HelperConnection) async {
        let info = connection.info
        guard started, !stopping, sessions.count < options.maxSessions, sessions[info.sessionID] == nil else {
            await connection.close(code: stopping ? .helperShuttingDown : .internalError, reason: "too many sessions")
            return
        }
        let session = HelperSession(connection: connection, host: self, resources: makeResources())
        let wasIdle = sessions.isEmpty
        sessions[info.sessionID] = Entry(session: session, task: Task {}, info: info)
        hub.update { $0.sessions.append(HelperStatus.Session(info: info, connectedAt: options.now())) }
        if wasIdle { dependencies.awake.acquire() }
        await startStageIfNeeded()
        guard sessions[info.sessionID] != nil else { return }  // stop() or an early disconnect ran meanwhile
        await session.start()
        let task = Task { [weak self] in
            await connection.run(handler: session)
            await self?.sessionEnded(info.sessionID)
        }
        if sessions[info.sessionID] != nil { sessions[info.sessionID]?.task = task } else { task.cancel() }
    }

    private func makeResources() -> HelperResources {
        let pasteboard = dependencies.pasteboard, transcoder = dependencies.transcoder
        return HelperResources(
            tracker: tracker, catalog: catalog, injector: injector, menus: menus, inbox: inbox, capture: dependencies.captureSystem,
            makeEncoder: dependencies.makeEncoder,
            makeClipboard: { PasteboardBridge(pasteboard: pasteboard, transcoder: transcoder) },
            audio: dependencies.audio, permissions: dependencies.permissions, options: options)
    }

    private func sessionEnded(_ id: UInt64) async {
        guard let entry = sessions.removeValue(forKey: id) else { return }
        await entry.session.shutdown()
        hub.update { $0.sessions.removeAll { $0.id == id } }
        await injector.releaseAll()
        if sessions.isEmpty {
            dependencies.awake.release()
            await endStageIfIdle()
        }
    }

    // MARK: Stage

    /// Stage start and end run one after the other, each re-checking whether any session is connected when its turn comes.
    private func enqueueStage(_ operation: @escaping @Sendable () async -> Void) async {
        let previous = stageChain
        let task = Task {
            await previous?.value
            await operation()
        }
        stageChain = task
        await task.value
    }

    private func startStageIfNeeded() async {
        await enqueueStage { [weak self] in await self?.stageStartNow() }
    }

    private func endStageIfIdle() async {
        await enqueueStage { [weak self] in await self?.stageEndNow() }
    }

    private func stageStartNow() async {
        guard !sessions.isEmpty, !stageRunning else { return }
        stageRunning = true
        await stage.start(display: options.stageDisplay)
    }

    private func stageEndNow() async {
        guard sessions.isEmpty, stageRunning else { return }
        stageRunning = false
        await stage.end()
    }

    private func stageChanged(_ state: LinkStageState) async {
        broadcast(.stage(state))
        if state == .unavailable { broadcast(.stageUnavailable) }
    }

    // MARK: Conditions

    private func currentPermissions() -> (accessibility: LinkPermissionState, screenRecording: LinkPermissionState) {
        var accessibility = dependencies.permissions.state(of: .accessibility)
        // The permission can read as granted while posting events is still refused (it is a separate, newer check).
        if accessibility == .granted, !dependencies.eventPoster.canPostEvents { accessibility = .denied }
        return (accessibility, dependencies.permissions.state(of: .screenRecording))
    }

    private func refreshPermissions() async {
        let now = currentPermissions()
        let before = hub.current
        hub.update { $0.accessibility = now.accessibility; $0.screenRecording = now.screenRecording }
        if before.accessibility != now.accessibility { broadcastPermission(.accessibility, now.accessibility) }
        if before.screenRecording != now.screenRecording { broadcastPermission(.screenRecording, now.screenRecording) }
    }

    private func broadcastPermission(_ kind: LinkPermissionKind, _ state: LinkPermissionState) {
        broadcast(.permission(kind, state))
        if state != .granted { broadcast(.permissionMissing(kind)) }
    }

    private func pollSecureInput() async {
        guard !sessions.isEmpty else { return }
        await injector.pollSecureInput()
    }

    private func injectorEvent(_ event: InputInjectorEvent) async {
        switch event {
        case .secureInputChanged(let enabled):
            hub.update { $0.secureInput = enabled }
            // The protocol has no "secure input ended" status; the iPad learns about the start only (see the open issues).
            if enabled { broadcast(.secureInput(pid: await frontmostPID())) }
        case .postingNotPermitted:
            await refreshPermissions()
            if hub.current.accessibility != .denied {
                hub.update { $0.accessibility = .denied }
                broadcastPermission(.accessibility, .denied)
            }
        }
    }

    private func lockChanged(_ locked: Bool) {
        guard hub.current.macLocked != locked else { return }
        hub.update { $0.macLocked = locked }
        broadcast(.macLocked(locked))
    }

    private func cleanInbox() async { await inbox?.cleanup() }

    private func frontmostPID() async -> Int32? {
        let snapshot = await tracker.snapshot()
        guard let active = snapshot.activeWindow else { return nil }
        return snapshot.windows.first { $0.id == active }?.pid
    }

    /// Sends a status message to every connected iPad.
    private func broadcast(_ status: LinkStatus) {
        let targets = sessions.values.map(\.session)
        for session in targets { Task { await session.deliver(status: status) } }
    }
}

// MARK: - What sessions need from the service

extension HelperService: HelperSessionHost {
    func conditions() async -> HelperConditions {
        let current = hub.current
        return HelperConditions(
            accessibility: current.accessibility, screenRecording: current.screenRecording, stage: current.stage,
            macLocked: current.macLocked, secureInput: current.secureInput, frontmostPID: await frontmostPID())
    }

    func subscriptionsChanged(session: UInt64, added: Set<WindowID>, removed: Set<WindowID>) async {
        var firstSubscribers: [WindowID] = []
        var lastSubscribers: [WindowID] = []
        for window in added {
            var owners = windowRefs[window] ?? []
            if owners.isEmpty { firstSubscribers.append(window) }
            owners.insert(session)
            windowRefs[window] = owners
        }
        for window in removed {
            guard var owners = windowRefs[window] else { continue }
            owners.remove(session)
            if owners.isEmpty {
                windowRefs[window] = nil
                lastSubscribers.append(window)
            } else {
                windowRefs[window] = owners
            }
        }
        // Authorise before the stage moves anything, and revoke before it puts windows back.
        await injector.setAuthorizedWindows(Set(windowRefs.keys))
        let count = windowRefs.values.filter { $0.contains(session) }.count
        hub.update { status in
            if let index = status.sessions.firstIndex(where: { $0.id == session }) { status.sessions[index].subscribedWindows = count }
        }
        for window in firstSubscribers { await manage(window) }
        for window in lastSubscribers { await stage.release(window: window) }
    }

    private func manage(_ window: WindowID) async {
        guard let info = await tracker.info(of: window), !info.flags.contains(.fullScreen), !info.flags.contains(.minimised),
              let key = await tracker.stageKey(of: window) else { return }
        do {
            try await stage.manage(window: window, key: key, sceneSize: info.frame.size)
        } catch {
            log.notice("window could not be placed on the stage")
        }
    }

    func requestStageSize(window: WindowID, size: LinkSize) async {
        await stage.requestSize(window: window, sceneSize: size)
    }

    func reportPermissionDenied(_ kind: LinkPermissionKind) async {
        switch kind {
        case .screenRecording:
            guard hub.current.screenRecording != .denied else { return }
            hub.update { $0.screenRecording = .denied }
            broadcastPermission(.screenRecording, .denied)
        case .accessibility:
            guard hub.current.accessibility != .denied else { return }
            hub.update { $0.accessibility = .denied }
            broadcastPermission(.accessibility, .denied)
        default:
            break
        }
    }

    func inject(_ message: LinkMessage, keyboardWindow: WindowID?) async {
        let injector = injector
        await inputGate.run {
            if let keyboardWindow { await injector.setKeyboardWindow(keyboardWindow) }
            await injector.handle(message)
        }
    }

    func claimAudio(pid: Int32, session: UInt64) async -> Bool {
        if let owner = audioOwners[pid], owner != session { return false }
        audioOwners[pid] = session
        return true
    }

    func releaseAudio(pid: Int32, session: UInt64) async {
        if audioOwners[pid] == session { audioOwners[pid] = nil }
    }

    func allocateTransfer() async -> TransferID {
        defer { nextTransfer &+= 1 }
        return TransferID(nextTransfer)
    }
}
#endif
