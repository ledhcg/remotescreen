import ConnectionKit
import Foundation
import InputKit
import Network
import Observation
import RFBKit
import RemoteDisplay
import SessionKit
import UIKit

/// Controls the lifecycle of one connection: opens it, receives updates, pushes them to the view, forwards the user's input to the Mac,
/// reconnects automatically when it drops, and disconnects.
///
/// Runs on the main actor. The heavy decoding lives in `RFBSession` (its own actor), so the main thread only receives
/// a copy of the frame (copy-on-write) and pushes the changed regions to the GPU.
@MainActor
@Observable
final class SessionController {
    enum State: Equatable {
        case idle
        case connecting
        case connected(name: String)
        /// It had connected before but dropped, and is retrying. The last screen stays visible, input is ignored.
        case reconnecting(name: String, attempt: Int, of: Int)
        case failed(String)
    }

    private(set) var state: State = .idle
    /// Security warning for the current session (weak VNC password, no authentication), shown for the whole session.
    private(set) var securityWarning: String?
    private(set) var touchMode: TouchMode = .directTouch
    private(set) var isKeyboardVisible = false
    /// Fit, fill or native pixels. Persisted between launches.
    private(set) var displayMode: DisplayMode
    private(set) var isKeyBarVisible = false
    /// "View only" (Observe): no mouse or key events are sent to the Mac, only the picture is received. The clipboard is not pushed to the Mac either.
    private(set) var isViewOnly = false
    /// Draw the Mac cursor on screen (the server does not draw it into the frame).
    private(set) var isRemoteCursorVisible = true
    /// Stream statistics panel (frames/s, Mbit/s, decode ms, draw ms): to tell whether lag comes from the network, decoding or drawing.
    private(set) var isStatsVisible = false
    private(set) var streamStats: StreamStats?
    /// Modifier keys currently pressed on the Mac via the sidebar or extra-keys bar: held, sticky once, or locked. A key missing here is `.up`.
    private(set) var modifierStates: [StickyModifier: ModifierState] = [:]
    /// Sidecar-style modifier-key sidebar: left, right or hidden. Persisted between launches.
    private(set) var sidebarPosition: SidebarPosition
    /// The connected server is Apple's `screensharingd`: only then are smooth scrolling and pinch/rotate on the Mac available (message 23).
    private(set) var isAppleServer = false
    /// Trackpad-style scrolling with inertia on the Mac (message 23 type 11), on by default. Tested on a real Mac: apps receive scrolling
    /// precisely in points, with all phases and inertia. When off, scrolling uses standard RFB wheel notches.
    private(set) var smoothScroll: Bool
    /// Two-finger pinch/rotate: zoom the viewport on the iPad (default) or send to the Mac (message 23 type 3, 5 version 2, tested for real).
    private(set) var pinchSendsToMac: Bool
    /// What a double tap on Apple Pencil does. Persisted between launches.
    private(set) var pencilDoubleTapAction: PencilDoubleTapAction
    /// After the first pencil stroke, fingers only scroll and zoom (like Sidecar). Defaults to the system setting "Only Draw with Apple Pencil".
    private(set) var fingersOnlyScrollWithPencil: Bool

    let clipboard: ClipboardBridge
    /// Picture quality mode, persisted between launches (`UserDefaults`).
    private(set) var qualityMode: QualityMode
    /// Briefly reconnecting to apply the new color depth (the user just changed the quality mode). Lets the banner say what is actually happening.
    private(set) var isApplyingQuality = false
    /// The frame-rate cap currently applied (`nil` means unlimited), shown in the statistics panel.
    private(set) var currentMaxFramesPerSecond: Int?
    /// When to retry connecting, and when to stop. Change `ReconnectPolicy.standard` to tune the experience.
    @ObservationIgnored var reconnectPolicy = ReconnectPolicy.standard

    /// Returning from the background after longer than this means the old connection is considered dead and we reconnect right away, instead of waiting for the OS to report an error.
    static let staleAfterBackground: TimeInterval = 10
    /// A session that lives at least this long resets the next drop to the start of the backoff table. Prevents a "connects then drops immediately" loop.
    static let stableSessionDuration: Duration = .seconds(30)

    private struct Request {
        let target: SavedConnection.Target
        let username: String
        let password: String
        let onConnected: (@MainActor () -> Void)?
    }

    @ObservationIgnored private var governor = AdaptiveGovernor()
    /// Counters for the current statistics window; the receive loop adds to them and a separate clock reads them every second (even when the screen is idle).
    @ObservationIgnored private var pacing = FramePacing()
    @ObservationIgnored private var windowUpdates = 0
    @ObservationIgnored private var windowDraw = Duration.zero
    /// View size in device pixels, and the downscale factor the server was asked to apply for the current session (`nil` means not sent, i.e. 1).
    @ObservationIgnored private var viewPixelSize = CGSize.zero
    @ObservationIgnored private var serverScaleSent: Double?
    @ObservationIgnored private var scalingTask: Task<Void, Never>?
    /// Color depth of the open (or just opened) session: compared with the new mode to know whether changing mode needs a reconnect.
    @ObservationIgnored private var sessionDepth: ColorDepth?
    /// The next drop is us deliberately reconnecting to change quality: retry immediately, do not wait, and do not count it against the retry attempts.
    @ObservationIgnored private var reconnectingForQuality = false
    @ObservationIgnored private let defaults: UserDefaults
    static let qualityModeKey = "qualityMode"
    static let displayModeKey = "displayMode"
    static let sidebarPositionKey = "sidebarPosition"
    static let pencilDoubleTapKey = "pencilDoubleTap"
    static let smoothScrollKey = "appleSmoothScroll"
    static let pinchToMacKey = "pinchSendsToMac"
    static let pencilFingersKey = "pencilFingersOnlyScroll"

    /// `UserDefaults` used for session settings. The debug build lets UI tests isolate it via `RFB_DEFAULTS_SUITE=<name>`, so the quality
    /// mode one test picks does not leak into another (each test uses its own name).
    static func environmentDefaults() -> UserDefaults {
        #if DEBUG
        if let suite = ProcessInfo.processInfo.environment["RFB_DEFAULTS_SUITE"], let defaults = UserDefaults(suiteName: suite) {
            return defaults
        }
        #endif
        return .standard
    }

    @ObservationIgnored private var request: Request?
    @ObservationIgnored private var session: RFBSession?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private weak var screenView: RemoteScreenView?
    /// The latest cursor image, because the server only sends it when the image changes: a view created later must still have it.
    @ObservationIgnored private var latestCursor: CursorImage?

    @ObservationIgnored private var wakeRequested = false
    @ObservationIgnored private var backgroundedAt: Date?
    @ObservationIgnored private var networkMonitor: NWPathMonitor?
    @ObservationIgnored private var networkWasDown = false

    /// DEBUG BUILD ONLY: drop all mouse and key events before sending, letting only the clipboard through. For testing the clipboard against a real Mac
    /// without any chance of controlling it by mistake (even ⌘V only sends the clipboard and does not actually paste). Enabled with `RFB_DROP_INPUT=1`.
    @ObservationIgnored private var dropsInputForTesting = false
    /// DEBUG BUILD ONLY: open the stream statistics panel at the start of every session (`RFB_STATS=1`), to measure on an iPad when the menu cannot be tapped.
    @ObservationIgnored private var showsStatsByDefault = false

    init(clipboard: ClipboardBridge = ClipboardBridge(pasteboard: SystemPasteboard()), defaults: UserDefaults = .standard) {
        self.clipboard = clipboard
        self.defaults = defaults
        qualityMode = defaults.string(forKey: Self.qualityModeKey).flatMap(QualityMode.init(rawValue:)) ?? .default
        displayMode = defaults.string(forKey: Self.displayModeKey).flatMap(DisplayMode.init(rawValue:)) ?? .default
        sidebarPosition = defaults.string(forKey: Self.sidebarPositionKey).flatMap(SidebarPosition.init(rawValue:)) ?? .default
        smoothScroll = defaults.object(forKey: Self.smoothScrollKey) as? Bool ?? true
        pinchSendsToMac = defaults.bool(forKey: Self.pinchToMacKey)
        pencilDoubleTapAction = defaults.string(forKey: Self.pencilDoubleTapKey).flatMap(PencilDoubleTapAction.init(rawValue:))
            ?? .secondaryClick
        fingersOnlyScrollWithPencil = defaults.object(forKey: Self.pencilFingersKey) as? Bool
            ?? UIPencilInteraction.prefersPencilOnlyDrawing
        currentMaxFramesPerSecond = qualityMode.initialMaxFramesPerSecond
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        dropsInputForTesting = environment["RFB_DROP_INPUT"] == "1"
        isKeyBarVisible = environment["RFB_KEYBAR"] == "1"
        showsStatsByDefault = environment["RFB_STATS"] == "1"
        if let value = environment["RFB_SMOOTH_SCROLL"] { smoothScroll = value == "1" }
        if environment["RFB_PINCH_TO_MAC"] == "1" { pinchSendsToMac = true }
        if let position = environment["RFB_SIDEBAR"].flatMap(SidebarPosition.init(rawValue:)) { sidebarPosition = position }
        if let mode = environment["RFB_QUALITY"].flatMap(QualityMode.init(rawValue:)) {
            qualityMode = mode
            currentMaxFramesPerSecond = mode.initialMaxFramesPerSecond
        }
        isStatsVisible = showsStatsByDefault
        #endif
    }

    /// Attach the display view. If a frame already exists, show it immediately.
    func attach(_ view: RemoteScreenView) {
        screenView = view
        // User input goes through the session's ordered queue, so a "press" always reaches the Mac before its "release".
        view.onInput = { [weak self] messages in self?.sendUserInput(messages) }
        view.touchPolicy = touchPolicy
        view.pinchSendsToMac = pinchSendsToMac && isAppleServer
        view.showsRemoteCursor = isRemoteCursorVisible
        view.displayMode = displayMode
        view.acceptsRemoteInput = !isViewOnly
        view.onPixelSizeChange = { [weak self] size in self?.viewPixelSizeChanged(size) }
        view.drawsLocalCursor = sessionDepth != .reduced // 16-bit: the server draws the cursor itself, drawing another would give two cursors
        view.onContentPresented = { [weak self] time, merged in self?.pacing.recordPresent(at: time, mergedUpdates: merged) }
        view.onModifierStatesChange = { [weak self] states in self?.modifierStates = states }
        view.fingersOnlyScrollWithPencil = fingersOnlyScrollWithPencil
        view.onPencilDoubleTap = { [weak self] in self?.pencilDoubleTapped() }
        if let latestCursor { view.setCursor(latestCursor) }
        // The view was created after a frame arrived (SwiftUI builds views later than data arrives): take the current frame from the session.
        // Do NOT keep a copy of the frame in the controller: the copy shares memory with the session, so every later update would force the
        // session to copy the whole 14.7 MB (2560x1440 screen) even if only a few pixels changed, for example while typing.
        if let session {
            Task { @MainActor [weak view] in
                let frame = await session.framebuffer
                view?.display(frame)
            }
        }
    }

    /// User input. While reconnecting there is no session to send to: drop it instead of writing to a dead connection.
    private func sendUserInput(_ messages: [ClientMessage]) {
        guard let session, !isViewOnly else { return }
        var outgoing = clipboard.prepareOutgoing(messages)
        #if DEBUG
        if dropsInputForTesting {
            outgoing = outgoing.filter {
                switch $0 {
                case .pointerEvent, .keyEvent: false
                default: true
                }
            }
        }
        #endif
        session.post(outgoing)
    }

    // MARK: - Connecting

    func connect(host: String, port: UInt16, username: String, password: String, onConnected: (@MainActor () -> Void)? = nil) {
        connect(target: .host(host, port: port), username: username, password: password, onConnected: onConnected)
    }

    /// - Parameter onConnected: runs on the main actor as soon as the first connection succeeds (for example to save the computer to the list).
    ///   Not run again on automatic reconnects.
    func connect(target: SavedConnection.Target, username: String, password: String, onConnected: (@MainActor () -> Void)? = nil) {
        switch state {
        case .connecting, .reconnecting: return
        default: break
        }
        request = Request(target: target, username: username, password: password, onConnected: onConnected)
        resetSessionControls()
        state = .connecting
        task?.cancel()
        startNetworkWatch()
        task = Task { [weak self] in await self?.connectionLoop() }
    }

    func disconnect() {
        screenView?.releaseAllInput() // release keys and mouse buttons before closing, so the Mac is not left with a stuck key
        task?.cancel()
        stopNetworkWatch()
        request = nil
        let closing = session
        session = nil
        securityWarning = nil
        clipboard.sessionEnded()
        latestCursor = nil
        reconnectingForQuality = false
        isApplyingQuality = false
        serverScaleSent = nil
        scalingTask?.cancel()
        resetSessionControls()
        state = .idle
        Task { await closing?.close() }
    }

    /// A live session exists to receive input (not while connecting or reconnecting).
    var isLive: Bool {
        if case .connected = state { return true }
        return false
    }

    /// The app window lost focus (switched to another window of the same app, Stage Manager): the key and button releases would not reach
    /// this view, so release right now. The app-level notification (`willResignActive`) does not fire when switching between windows of the same app.
    func sceneDidDeactivate() {
        screenView?.releaseAllInput()
    }

    /// Dismiss the connection error and return to the idle state. Only has an effect while in `.failed`.
    func dismissFailure() {
        if case .failed = state { state = .idle }
    }

    /// Every session starts from the default configuration: a new view is always in fit mode, with the keyboard off, and in control mode.
    /// Without resetting, the toolbar buttons would show "on" while the new view has not followed.
    private func resetSessionControls() {
        isViewOnly = false
        isStatsVisible = showsStatsByDefault
        streamStats = nil
        isRemoteCursorVisible = true
        isKeyboardVisible = false
        isKeyBarVisible = false
        modifierStates = [:]
    }

    /// Open a session; when a session that was alive drops, wait and reopen according to `reconnectPolicy`.
    /// If the very first open fails, report immediately (a wrong address or password should not be silently repeated).
    private func connectionLoop() async {
        guard let request else { return }
        let hasUsername = !request.username.isEmpty
        var retriesMade = 0
        var everConnected = false
        var name = ""

        while !Task.isCancelled {
            var current: RFBSession?
            var connectedAt: ContinuousClock.Instant?
            do {
                let depth = qualityMode.colorDepth
                let opened = try await RFBConnection.open(
                    endpoint: request.target.endpoint, credentials: RFBCredentials(username: request.username, password: request.password),
                    pixelFormat: depth.pixelFormat
                )
                sessionDepth = depth
                current = opened
                guard !Task.isCancelled else {
                    await opened.close()
                    return
                }
                session = opened
                name = opened.serverInfo.name
                state = .connected(name: name)
                securityWarning = ConnectionSecurityNotice.sessionWarning(for: opened.securityType)
                isApplyingQuality = false
                connectedAt = .now
                clipboard.sessionStarted(flavor: opened.flavor) { [weak self] messages in self?.session?.post(messages) }
                isAppleServer = opened.flavor == .apple
                applyServerFeatures()
                // The user changed the quality mode while this connection was in progress: the color depth just opened is stale. Reconnect right away.
                if qualityMode.colorDepth != depth {
                    isApplyingQuality = true
                    reconnectingForQuality = true
                    forceReconnect()
                }
                if !everConnected {
                    everConnected = true
                    request.onConnected?()
                }
                try await run(opened)
            } catch {
                // A deliberate disconnect closes the stream and throws; that is not an error to report.
                if Task.isCancelled { return }
                session = nil
                clipboard.sessionEnded()
                screenView?.releaseAllInput() // clear old key/touch state (input was dropped because there is no session)
                await current?.close()
                // The user pressed Disconnect while closing: `disconnect()` already set the state, do not overwrite it.
                if Task.isCancelled { return }

                guard everConnected else {
                    stopNetworkWatch()
                    self.request = nil // do not keep the password in memory after failing
                    state = .failed(ConnectionFailureMessage.text(for: error, hasUsername: hasUsername))
                    return
                }
                if reconnectingForQuality {
                    // We closed the session ourselves to change the color depth: reconnect immediately, do not wait, and do not count it as a retry due to lost connection.
                    reconnectingForQuality = false
                    retriesMade = 0
                    state = .reconnecting(name: name, attempt: 1, of: reconnectPolicy.maxAttempts)
                    continue
                }
                isApplyingQuality = false
                if let connectedAt, ContinuousClock.now - connectedAt > Self.stableSessionDuration { retriesMade = 0 }

                switch reconnectPolicy.decision(after: error, attemptsMade: retriesMade) {
                case .retry(let delay, let attempt):
                    retriesMade = attempt
                    state = .reconnecting(name: name, attempt: attempt, of: reconnectPolicy.maxAttempts)
                    await wait(delay)
                case .giveUp(let reason):
                    stopNetworkWatch()
                    self.request = nil
                    latestCursor = nil
                    state = .failed(ConnectionFailureMessage.giveUp(
                        reason, error: error, name: name, attempts: retriesMade, hasUsername: hasUsername
                    ))
                    return
                }
            }
        }
    }

    /// Wait `delay`, or less if signaled: the network just came back, or the app just returned from the background.
    private func wait(_ delay: Duration) async {
        wakeRequested = false
        let end = ContinuousClock.now + delay
        while ContinuousClock.now < end, !wakeRequested, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    // MARK: - Background and network

    func appDidEnterBackground() {
        backgroundedAt = Date()
    }

    func appDidBecomeActive() {
        defer { backgroundedAt = nil }
        switch state {
        case .reconnecting:
            wakeRequested = true // the user is back: retry now, do not wait out the backoff
        case .connected:
            if let backgroundedAt, Date().timeIntervalSince(backgroundedAt) > Self.staleAfterBackground {
                forceReconnect()
            }
        default:
            break
        }
    }

    /// Close the current session so the connection loop treats it as dropped and reconnects. Used when the connection is suspected dead but the OS has not reported it.
    func forceReconnect() {
        guard let old = session else { return }
        // Release keys, buttons and sticky keys BEFORE closing (the session is still alive, so the releases still reach the Mac). After closing they would be dropped
        // while the UI already considers them released, and ⌘ could get stuck on the Mac.
        screenView?.releaseAllInput()
        Task { await old.close() }
    }

    private func startNetworkWatch() {
        stopNetworkWatch()
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            Task { @MainActor in self?.networkChanged(satisfied: satisfied) }
        }
        monitor.start(queue: DispatchQueue(label: "RemoteScreen.NetworkWatch"))
        networkMonitor = monitor
    }

    private func stopNetworkWatch() {
        networkMonitor?.cancel()
        networkMonitor = nil
        networkWasDown = false
    }

    /// The network is back after being lost: if waiting to reconnect, retry now.
    private func networkChanged(satisfied: Bool) {
        if satisfied, networkWasDown { wakeRequested = true }
        networkWasDown = !satisfied
    }

    // MARK: - UI controls

    func toggleTouchMode() {
        touchMode = touchMode == .directTouch ? .trackpad : .directTouch
        screenView?.touchPolicy = touchPolicy
    }

    /// The current touch style, plus smooth scrolling when the server is Apple and the user enabled it.
    private var touchPolicy: TouchPolicy {
        var policy = TouchPolicy(mode: touchMode)
        policy.appleSmoothScroll = smoothScroll && isAppleServer
        return policy
    }

    /// The server just changed (new connection, reconnect): re-apply whatever depends on an Apple server.
    private func applyServerFeatures() {
        screenView?.touchPolicy = touchPolicy
        screenView?.pinchSendsToMac = pinchSendsToMac && isAppleServer
    }

    func setSmoothScroll(_ enabled: Bool) {
        smoothScroll = enabled
        defaults.set(enabled, forKey: Self.smoothScrollKey)
        applyServerFeatures()
    }

    func setPinchSendsToMac(_ enabled: Bool) {
        pinchSendsToMac = enabled
        defaults.set(enabled, forKey: Self.pinchToMacKey)
        applyServerFeatures()
    }

    func toggleKeyboard() {
        isKeyboardVisible.toggle()
        screenView?.isSoftwareKeyboardVisible = isKeyboardVisible
    }

    func toggleKeyBar() {
        isKeyBarVisible.toggle()
    }

    func toggleModifier(_ modifier: StickyModifier) {
        screenView?.toggleModifier(modifier)
    }

    func press(_ key: VirtualKey) {
        screenView?.press(key)
    }

    func modifierTouchDown(_ modifier: StickyModifier) {
        screenView?.modifierTouchDown(modifier)
    }

    func modifierTouchUp(_ modifier: StickyModifier) {
        screenView?.modifierTouchUp(modifier)
    }

    /// The sidebar Undo button: ⌘Z on the Mac (with ⇧ sticky it becomes ⌘⇧Z, redo).
    func undo() {
        screenView?.pressCommandChord("z")
    }

    func setPencilDoubleTapAction(_ action: PencilDoubleTapAction) {
        pencilDoubleTapAction = action
        defaults.set(action.rawValue, forKey: Self.pencilDoubleTapKey)
    }

    func setFingersOnlyScrollWithPencil(_ enabled: Bool) {
        fingersOnlyScrollWithPencil = enabled
        defaults.set(enabled, forKey: Self.pencilFingersKey)
        screenView?.fingersOnlyScrollWithPencil = enabled
    }

    private func pencilDoubleTapped() {
        switch pencilDoubleTapAction {
        case .secondaryClick: screenView?.secondaryClickAtPointer()
        case .toggleKeyboard: toggleKeyboard()
        case .nothing: break
        }
    }

    func setSidebarPosition(_ position: SidebarPosition) {
        guard position != sidebarPosition else { return }
        // Hiding the sidebar releases sticky or locked modifier keys: there would be nowhere left to see or cancel them.
        if position == .hidden, !isKeyBarVisible { screenView?.releaseModifiers() }
        sidebarPosition = position
        defaults.set(position.rawValue, forKey: Self.sidebarPositionKey)
    }

    /// Switch between control and view only. Release every held key and button **before** blocking, so the Mac is not left with a stuck key.
    func setViewOnly(_ viewOnly: Bool) {
        guard viewOnly != isViewOnly else { return }
        if viewOnly {
            screenView?.releaseAllInput()
            if isKeyboardVisible { toggleKeyboard() }
            isKeyBarVisible = false
        }
        isViewOnly = viewOnly
        screenView?.acceptsRemoteInput = !viewOnly
    }

    /// Change the quality mode. The frame rate changes immediately; the color depth cannot change mid-session (see `ColorDepth`), so if needed
    /// briefly reconnect (about one second, the last screen stays visible) to apply it.
    func setQualityMode(_ mode: QualityMode) {
        guard mode != qualityMode else { return }
        qualityMode = mode
        defaults.set(mode.rawValue, forKey: Self.qualityModeKey)
        governor = AdaptiveGovernor()
        currentMaxFramesPerSecond = mode.initialMaxFramesPerSecond
        guard let session else { return } // no session yet: applies on the next connection
        if sessionDepth != mode.colorDepth {
            isApplyingQuality = true
            reconnectingForQuality = true
            forceReconnect()
        } else {
            let interval = currentMaxFramesPerSecond.minimumUpdateInterval
            Task { await session.setMinimumUpdateInterval(interval) }
            applyServerScaling() // "best performance" enables server-side downscaling, the other modes disable it
        }
    }

    /// The statistics line with the applied configuration, for example "20 fps · 12.3 Mbit/s · decode 1.9 ms · draw 0.7 ms · 16-bit · ≤20 fps".
    var statsLine: String {
        var line = streamStats?.summary ?? String(localized: "Measuring…")
        if sessionDepth == .reduced { line += " · 16 bit" }
        if let cap = currentMaxFramesPerSecond { line += " · " + String(localized: "≤\(cap) fps") }
        return line
    }

    func setStatsVisible(_ visible: Bool) {
        isStatsVisible = visible
        if !visible { streamStats = nil }
    }

    func setRemoteCursorVisible(_ visible: Bool) {
        isRemoteCursorVisible = visible
        screenView?.showsRemoteCursor = visible
    }

    func setDisplayMode(_ mode: DisplayMode) {
        guard mode != displayMode else { return }
        displayMode = mode
        defaults.set(mode.rawValue, forKey: Self.displayModeKey)
        screenView?.displayMode = mode
        applyServerScaling()
    }

    // MARK: - Server-side downscaling (match-device-resolution mode)

    private func viewPixelSizeChanged(_ size: CGSize) {
        viewPixelSize = size
        // Rotating the device or dragging Split View changes the size many times in a row: wait for the layout to settle and send once.
        scalingTask?.cancel()
        scalingTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self?.applyServerScaling()
        }
    }

    /// Ask the Apple server to downscale the picture to exactly the view's pixel size (message type 8), or return to the original size when leaving that mode.
    /// Other servers: do nothing (`.device` mode then behaves like fit).
    private func applyServerScaling() {
        guard let session, session.flavor == .apple else { return }
        let remote = CGSize(width: Double(session.serverInfo.width), height: Double(session.serverInfo.height))
        let wanted = displayMode.serverScale(remote: remote, viewPixels: viewPixelSize)
            ?? (qualityMode.prefersServerScaling ? DisplayMode.device.serverScale(remote: remote, viewPixels: viewPixelSize) : nil)
            ?? 1
        if let sent = serverScaleSent, abs(sent - wanted) < 0.002 { return }
        if serverScaleSent == nil, wanted == 1 { return } // a new session is already at the original size
        serverScaleSent = wanted
        session.post([.appleServerScaling(wanted)])
    }

    func setTouchMode(_ mode: TouchMode) {
        guard mode != touchMode else { return }
        toggleTouchMode()
    }

    // MARK: - Receive loop

    private func run(_ session: RFBSession) async throws {
        // The session requests the next update itself as soon as it receives the header of the current one (`pipelinesUpdateRequests`),
        // so this loop does not call `requestUpdate`: it only receives, decodes and draws.
        //
        // At 16-bit we do NOT request a separate cursor image: the RFC says cursor pixels use the client format, but we have not measured which format the Apple server
        // sends it in (it only sends the cursor after the viewer has controlled the mouse). Without it the server draws the cursor into the
        // frame: worst case the cursor lags slightly, but the stream never goes out of sync and the session never drops.
        let encodings: [RFBEncoding] = sessionDepth == .reduced
            ? [.zrle, .copyRect, .desktopSize]
            : [.zrle, .copyRect, .cursor, .desktopSize]
        try await session.start(encodings: encodings)
        screenView?.drawsLocalCursor = sessionDepth != .reduced
        pacing = FramePacing()
        // New session: the adaptive controller starts again from the full tier, unless the mode has a fixed cap.
        governor = AdaptiveGovernor()
        currentMaxFramesPerSecond = qualityMode.initialMaxFramesPerSecond
        await session.setMinimumUpdateInterval(currentMaxFramesPerSecond.minimumUpdateInterval)
        serverScaleSent = nil
        applyServerScaling()

        windowUpdates = 0
        windowDraw = .zero
        // Statistics and the adaptive controller run on their own clock: an idle screen produces no events, but it must still
        // report 0 frames/s and still count as "light" so the full rate is restored.
        let statsTask = Task { [weak self] in await self?.measureStats(of: session) }
        defer { statsTask.cancel() }

        while !Task.isCancelled {
            switch try await session.nextEvent() {
            case .framebufferUpdate(let dirty, let cursor):
                if let cursor {
                    latestCursor = cursor
                    screenView?.setCursor(cursor)
                }
                // A copy-on-write copy, released right after drawing (not kept) so the session does not have to copy the whole buffer.
                let drawStart = ContinuousClock.now
                let frame = await session.framebuffer
                screenView?.display(frame, dirty: dirty.isEmpty ? nil : dirty)
                windowDraw += ContinuousClock.now - drawStart
                windowUpdates += 1
            case .clipboard(let transfer):
                clipboard.receive(transfer)
            case .serverCutText(let text):
                clipboard.receive(cutText: text)
            case .clipboardSkipped(let bytes):
                clipboard.noteSkipped(bytes: bytes)
            case .bell, .colourMapIgnored:
                break
            }
        }
    }

    /// Every second: compute figures from the delta of `session.statistics` and the receive loop's counters, then let the adaptive controller look.
    private func measureStats(of session: RFBSession) async {
        var baseline = await session.statistics
        var windowStart = ContinuousClock.now
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            let now = ContinuousClock.now
            let snapshot = await session.statistics
            var measured = StreamStats.measure(
                updates: windowUpdates,
                wireBytes: snapshot.payloadBytes.values.reduce(0, +) - baseline.payloadBytes.values.reduce(0, +),
                decode: snapshot.decodeTime - baseline.decodeTime,
                draw: windowDraw,
                over: now - windowStart
            )
            if windowUpdates == 0 { pacing.resetBaseline() } // an idle screen is not stutter
            measured?.pacing = pacing.drain()
            windowUpdates = 0
            windowDraw = .zero
            baseline = snapshot
            windowStart = now
            if isStatsVisible {
                streamStats = measured
                #if DEBUG
                // To the device console (devicectl --console) to read exact figures when the mirrored image is too small.
                if measured != nil { print("RS_STATS \(statsLine)") }
                #endif
            }
            if qualityMode == .adaptive, let measured, let change = governor.observe(measured) {
                currentMaxFramesPerSecond = change.maxFramesPerSecond
                await session.setMinimumUpdateInterval(change.maxFramesPerSecond.minimumUpdateInterval)
            }
        }
    }
}
