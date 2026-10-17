import ConnectionKit
import InputKit
import LinkProtocol
import RemoteDisplay
import SessionKit
import SwiftUI
import UIKit
import WindowKit

/// Type of the `NSUserActivity` each remote-window scene publishes (declared in `NSUserActivityTypes`).
enum AppModeActivity {
    static let windowType = "com.ledinhcuong.screon.window"
}

/// State of one remote-window scene: which window it shows, its input encoder, the debounced stream size, the size of the Mac window,
/// and the menus and key commands of the Mac app in it.
@available(iOS 26, *)
@MainActor
@Observable
final class RemoteWindowSceneModel {
    let computerID: UUID
    let ref: WindowRef
    let sceneID = SceneID(UUID().uuidString)

    private(set) var connection: AppModeConnection?
    var fitMode: WindowFitMode = .fit
    var isKeyboardVisible = false

    @ObservationIgnored weak var view: AppWindowView?
    @ObservationIgnored private(set) weak var windowScene: UIWindowScene?
    @ObservationIgnored private weak var keyCommandHost: UIViewController?
    @ObservationIgnored private var encoder: LinkInputEncoder?
    @ObservationIgnored private var subscribedWindow: WindowID?
    @ObservationIgnored private var pixelSize: CGSize = .zero
    @ObservationIgnored private var resizeTask: Task<Void, Never>?
    @ObservationIgnored private var isPaused = false
    @ObservationIgnored private var debouncer = ResizeDebouncer()
    @ObservationIgnored private var frameTask: Task<Void, Never>?
    @ObservationIgnored private var contentSize: CGSize = .zero
    @ObservationIgnored private var installedKeyCommands: [UIKeyCommand] = []
    @ObservationIgnored private var appliedTitle: String?
    /// Set by the view: closes this scene.
    @ObservationIgnored var closeHandler: (() -> Void)?

    init(computerID: UUID, windowRef: String) {
        self.computerID = computerID
        ref = WindowRef(encoded: windowRef) ?? WindowRef(windowID: nil, query: nil)
    }

    // MARK: Lifecycle

    func start(registry: LinkSessionRegistry) {
        guard connection == nil, let connection = registry.acquireConnection(computerID: computerID) else { return }
        self.connection = connection
        connection.attach(scene: sceneID, ref: ref)
    }

    func stop(registry: LinkSessionRegistry) {
        guard let connection else { return }
        resizeTask?.cancel()
        frameTask?.cancel()
        removeKeyCommands()
        FocusedRemoteMenu.shared.blur(self)
        SceneRegistry.shared.unregister(sceneID)
        connection.detach(scene: sceneID)
        self.connection = nil
        subscribedWindow = nil
        registry.release(computerID: computerID)
    }

    /// The window this scene shows now, once the Mac's snapshot has told which it is.
    var boundWindow: WindowID? { connection?.bindingState(of: sceneID)?.windowID }

    var boundState: WindowState? { boundWindow.flatMap { connection?.workspace.window($0) } }

    /// The Mac app of the window this scene shows.
    var focusedBundleID: String? { boundState?.bundleID }

    /// Keeps the subscription in line with the bound window and the view size. Call whenever either changes.
    func syncSubscription() {
        guard let connection else { return }
        let window = boundWindow
        if let old = subscribedWindow, old != window {
            connection.unsubscribe(old)
            subscribedWindow = nil
            encoder = nil
        }
        guard let window, pixelSize.width > 0, !isPaused else { return }
        subscribedWindow = window
        let rate = windowScene?.screen.maximumFramesPerSecond ?? 60
        connection.subscribe(window: window, pixelSize: pixelSize, maxFramesPerSecond: rate)
    }

    /// The view was resized (Stage Manager, rotation): ask for a stream of the new size once it stops changing.
    func viewPixelSizeChanged(_ size: CGSize) {
        pixelSize = size
        resizeTask?.cancel()
        resizeTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            self?.syncSubscription()
        }
    }

    // MARK: Scene and geometry

    /// The scene the view lives in is known.
    func sceneAvailable(_ scene: UIWindowScene?) {
        guard let scene else { return }
        windowScene = scene
        SceneRegistry.shared.register(sceneID, scene: scene)
        applyWindowMetadata()
    }

    /// The view controller above the window view: key commands added to it reach the Mac app while this scene has the focus.
    func keyCommandHostAvailable(_ controller: UIViewController?) {
        guard let controller, controller !== keyCommandHost else { return }
        keyCommandHost = controller
        installKeyCommands()
    }

    /// Title of the scene and its size limits follow the Mac window (call when its title or limits change).
    func applyWindowMetadata() {
        guard let scene = windowScene, let state = boundState else { return }
        if appliedTitle != state.title, !state.title.isEmpty {
            appliedTitle = state.title
            scene.title = state.title
        }
        guard let restrictions = scene.sizeRestrictions else { return }
        let info = state.info
        let actions = WindowActionAvailability(window: state)
        if actions.canResize {
            let limits = SceneSizeLimits(minSize: info.minSize, maxSize: info.maxSize)
            restrictions.minimumSize = CGSize(width: limits.minimum.width, height: limits.minimum.height)
            restrictions.maximumSize = limits.maximum.map { CGSize(width: $0.width, height: $0.height) } ?? Self.noMaximum
        } else {
            // A window the Mac cannot resize keeps its size on the iPad too.
            let fixed = SceneSizeLimits(minSize: info.frame.size, maxSize: info.frame.size).clamp(info.frame.size)
            restrictions.minimumSize = CGSize(width: fixed.width, height: fixed.height)
            restrictions.maximumSize = CGSize(width: fixed.width, height: fixed.height)
        }
    }

    private static let noMaximum = CGSize(width: 10_000, height: 10_000)

    /// The area the window fills changed (points). A drag sends many of these; one `window.setFrame` leaves once it settles.
    func sceneSizeChanged(_ size: CGSize) {
        contentSize = size
        debouncer.observe(LinkSize(width: Double(size.width), height: Double(size.height)), at: Self.now)
        scheduleFrameSend()
    }

    /// "Resize the Mac window to fit this window", sent right away.
    func resizeMacWindowToScene() {
        sendFrame(LinkSize(width: Double(contentSize.width), height: Double(contentSize.height)))
    }

    private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    private func scheduleFrameSend() {
        guard frameTask == nil else { return }
        frameTask = Task { [weak self] in
            while !Task.isCancelled, let self, let deadline = self.debouncer.deadline {
                try? await Task.sleep(for: .seconds(max(0.05, deadline - Self.now)))
                guard !Task.isCancelled else { break }
                let resizing = self.windowScene?.effectiveGeometry.isInteractivelyResizing ?? false
                if let size = self.debouncer.poll(at: Self.now, isInteractivelyResizing: resizing) { self.sendFrame(size) }
            }
            self?.frameTask = nil
        }
    }

    private func sendFrame(_ size: LinkSize) {
        guard let connection, let state = boundState, WindowActionAvailability(window: state).canResize, size.width >= 1, size.height >= 1 else { return }
        let limits = SceneSizeLimits(minSize: state.info.minSize, maxSize: state.info.maxSize)
        connection.setFrame(window: state.id, size: limits.clamp(size))
    }

    // MARK: Focus

    func scenePhaseChanged(_ phase: ScenePhase) {
        guard let connection else { return }
        switch phase {
        case .background:
            isPaused = true
            view?.releaseAllInput()
            FocusedRemoteMenu.shared.blur(self)
            if let window = subscribedWindow { connection.pause(window: window) }
        case .inactive:
            view?.releaseAllInput()
            FocusedRemoteMenu.shared.blur(self)
        case .active:
            connection.appDidBecomeActive()
            FocusedRemoteMenu.shared.focus(self)
            if isPaused {
                isPaused = false
                if let window = subscribedWindow { connection.resume(window: window) } else { syncSubscription() }
            }
        @unknown default:
            break
        }
    }

    // MARK: Menus and key commands

    /// This scene has the focus: fetch its app's menu and take over the shortcuts.
    func focusGained() {
        if let bundleID = focusedBundleID { connection?.requestMenu(bundleID: bundleID) }
        installKeyCommands()
    }

    func pressMenu(bundleID: String, path: [UInt16]) {
        connection?.pressMenu(bundleID: bundleID, path: path)
    }

    /// The menu to show now. Waits a moment when nothing is cached yet; a cached tree is shown at once and refreshed behind it.
    func menuEntriesWaiting(bundleID: String) async -> [RemoteMenuEntry] {
        guard let connection else { return [] }
        let cached = connection.menuEntries(bundleID: bundleID)
        connection.requestMenu(bundleID: bundleID, force: true)
        if !cached.isEmpty { return cached }
        for _ in 0..<12 {
            try? await Task.sleep(for: .milliseconds(50))
            let entries = connection.menuEntries(bundleID: bundleID)
            if !entries.isEmpty { return entries }
        }
        return []
    }

    /// Mac key equivalents become key commands of this scene with priority over the system, so ⌘-shortcuts reach the Mac app. Shortcuts of
    /// iPadOS and Screon are left out, and ⌘W stays with Screon when it closes the iPad window.
    func installKeyCommands() {
        removeKeyCommands()
        guard let host = keyCommandHost, let connection, let bundleID = focusedBundleID else { return }
        let policy = AppModePreferences.closeShortcut
        let entries = connection.menuEntries(bundleID: bundleID)
        for command in RemoteMenuMapper.keyCommands(from: entries, closePolicy: policy) {
            let key = UIKeyCommand(
                title: command.title, image: nil, action: #selector(UIResponder.screonRemoteMenuItem(_:)), input: command.shortcut.input,
                modifierFlags: command.shortcut.modifiers.uiKit,
                propertyList: RemoteMenuBar.propertyList(bundleID: bundleID, path: command.path), alternates: [],
                discoverabilityTitle: nil, attributes: [], state: .off)
            key.wantsPriorityOverSystemBehavior = true
            host.addKeyCommand(key)
            installedKeyCommands.append(key)
        }
        if policy == .closeIPadWindow {
            let close = UIKeyCommand(
                title: String(localized: "Close window"), image: nil, action: #selector(UIResponder.screonCloseRemoteWindow(_:)),
                input: "w", modifierFlags: .command, propertyList: nil, alternates: [], discoverabilityTitle: nil, attributes: [], state: .off)
            close.wantsPriorityOverSystemBehavior = true
            host.addKeyCommand(close)
            installedKeyCommands.append(close)
        }
    }

    private func removeKeyCommands() {
        for command in installedKeyCommands { keyCommandHost?.removeKeyCommand(command) }
        installedKeyCommands = []
    }

    // MARK: Window actions

    func macCommand(_ command: LinkWindowCommand) {
        guard let window = boundWindow else { return }
        connection?.command(command, on: window)
    }

    func requestCloseScene() { closeHandler?() }

    /// Shows another window of the app in this scene (tabs, iPhone). A window that another scene shows comes forward there.
    func switchTo(_ window: WindowID) {
        guard let connection else { return }
        if case .focusExisting(let scene) = connection.switchScene(sceneID, to: window) { SceneRegistry.shared.activate(scene) }
    }

    // MARK: Input

    func send(_ intents: [InputIntent]) {
        guard let connection, let window = boundWindow else { return }
        if encoder?.window != window { encoder = LinkInputEncoder(window: window) }
        connection.sendInput(encoder?.encode(intents) ?? [])
    }
}

/// The scene of one Mac window.
@available(iOS 26, *)
struct RemoteWindowSceneView: View {
    let role: SceneRole
    let computerID: UUID
    @Environment(LinkSessionRegistry.self) private var registry
    @Environment(ConnectionsModel.self) private var computers
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(PhoneNavigation.self) private var phone: PhoneNavigation?
    @State private var model: RemoteWindowSceneModel
    @State private var pairing: SavedConnection?
    @State private var showsSettings = false
    @State private var showsMenus = false
    @AppStorage(AppModePreferences.openStyleKey) private var openStyle = AppOpenStyle.separateWindows.rawValue

    init(role: SceneRole, computerID: UUID, windowRef: String) {
        self.role = role
        self.computerID = computerID
        _model = State(initialValue: RemoteWindowSceneModel(computerID: computerID, windowRef: windowRef))
    }

    private var presentation: RemoteWindowPresentation {
        guard let connection = model.connection else { return RemoteWindowPresentation(overlay: .connecting) }
        let binding = connection.bindingState(of: model.sceneID)
        let hasFrame = binding?.windowID.map { connection.framesShown.contains($0) } ?? false
        return RemoteWindowStatus.present(
            connection: connection.phase, binding: binding, workspace: connection.workspace, helper: connection.helper, hasFrame: hasFrame
        )
    }

    private var opener: AppModeOpener {
        AppModeOpener(computerID: computerID, openWindow: openWindow, showHere: phone.map { phone in
            { window in if let connection = model.connection { phone.show(window, in: connection, computerID: computerID) } }
        })
    }

    /// Windows to offer in the tab bar: the app's windows with tabs, or every window on iPhone is offered by the switcher sheet instead.
    private var tabItems: [WindowSwitcherItem] {
        guard phone == nil, openStyle == AppOpenStyle.tabs.rawValue, let connection = model.connection, let bundleID = model.focusedBundleID else { return [] }
        let items = WindowSwitcher.items(
            workspace: connection.workspace, current: model.boundWindow, bindings: connection.bindings, thisScene: model.sceneID, onlyApp: bundleID)
        return items.count > 1 ? items : []
    }

    private var activityReference: String? {
        guard let connection = model.connection, let window = model.boundWindow else { return nil }
        return WindowRef(window: window, in: connection.workspace)?.encoded
    }

    var body: some View {
        let shown = presentation
        ZStack {
            AppWindowRepresentable(model: model, acceptsInput: shown.overlay?.coversWindow != true)
                .ignoresSafeArea()
            if let overlay = shown.overlay {
                RemoteWindowOverlayView(overlay: overlay, perform: perform)
            }
            VStack {
                if let banner = shown.banner {
                    Label(banner.text, systemImage: "lock.fill")
                        .font(.footnote)
                        .foregroundStyle(Theme.onChrome)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .chromeBanner()
                        .accessibilityIdentifier("secure-input-banner")
                }
                Spacer()
            }
            .padding(.top, 8)
            .allowsHitTesting(false)
            topBar
        }
        .background(.black)
        .preferredColorScheme(.dark) // a Mac window is chrome over black: its menus and alerts are dark too
        .background {
            SceneBridge(
                onScene: { scene in model.sceneAvailable(scene) },
                onSize: { size in model.sceneSizeChanged(size) },
                onController: { controller in model.keyCommandHostAvailable(controller) })
        }
        .onAppear {
            model.closeHandler = { closeScene() }
            model.start(registry: registry)
        }
        .onDisappear { model.stop(registry: registry) }
        .onChange(of: model.boundWindow) { _, _ in
            model.syncSubscription()
            model.applyWindowMetadata()
            if scenePhase == .active { model.focusGained() }
        }
        .onChange(of: model.boundState?.info.title) { _, _ in model.applyWindowMetadata() }
        .onChange(of: model.boundState?.capabilities) { _, _ in model.applyWindowMetadata() }
        .onChange(of: model.connection?.isConnected) { _, connected in
            // The menu asked for before the link was up was never sent: ask again as soon as it is.
            if connected == true, scenePhase == .active { model.focusGained() }
        }
        .onChange(of: model.connection?.menuRevision) { _, _ in
            model.installKeyCommands()
            FocusedRemoteMenu.shared.menusChanged()
        }
        .onChange(of: model.connection?.newWindows.toOpen) { _, _ in
            if let connection = model.connection { opener.openNewWindows(of: connection) }
        }
        .onChange(of: scenePhase) { _, phase in model.scenePhaseChanged(phase) }
        .userActivity(AppModeActivity.windowType, isActive: activityReference != nil) { activity in
            activity.targetContentIdentifier = activityReference
            activity.title = model.boundState?.title
            activity.userInfo = ["computer": computerID.uuidString, "ref": activityReference ?? ""]
            activity.isEligibleForHandoff = false
        }
        .sheet(item: $pairing) { computer in
            AppModePairingView(computer: computer, model: computers) {
                pairing = nil
                model.connection?.retry()
            }
        }
        .sheet(isPresented: $showsSettings) {
            WindowSettingsSheet(model: model, isPhone: phone != nil, openDesktop: { perform(.openDesktop) }, closeScene: { closeScene() })
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showsMenus) {
            RemoteMenuSheet(model: model)
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: Binding(get: { phone?.showsSwitcher ?? false }, set: { phone?.showsSwitcher = $0 })) {
            if let connection = model.connection, let phone {
                WindowSwitcherSheet(connection: connection, computerID: computerID, current: model.boundWindow, phone: phone)
            }
        }
    }

    // MARK: Top bar

    private var topBar: some View {
        VStack(spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                if let phone {
                    Button {
                        phone.showsSwitcher = true
                    } label: {
                        Image(systemName: "rectangle.stack")
                    }
                    .buttonStyle(ChromeRoundButtonStyle())
                    .accessibilityLabel("Windows")
                    .accessibilityIdentifier("window-switcher-button")
                }
                Spacer()
                menusButton
                windowMenu
            }
            let items = tabItems
            if !items.isEmpty { tabBar(items) }
            Spacer()
        }
        .padding(8)
    }

    private func tabBar(_ items: [WindowSwitcherItem]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(items) { item in
                    Button {
                        model.switchTo(item.id)
                    } label: {
                        Text(item.title.isEmpty ? item.appName : item.title)
                            .lineLimit(1)
                            .font(.footnote.weight(item.isCurrent ? .semibold : .regular))
                            .foregroundStyle(Theme.onChrome)
                            .padding(.horizontal, 14)
                            .frame(minHeight: Theme.Size.hit - 8)
                            .background(item.isCurrent ? Theme.accent : Theme.chrome, in: Capsule())
                            .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 1))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(HapticPlainStyle())
                    .accessibilityIdentifier("tab-\(item.id.rawValue)")
                }
            }
        }
        .frame(maxWidth: 520)
        .accessibilityIdentifier("window-tabs")
    }

    /// The Mac app's menu bar: a button that opens the menus as a bottom sheet (also the way to them where the system menu bar is not shown).
    private var menusButton: some View {
        Button { showsMenus = true } label: { Image(systemName: "filemenu.and.selection") }
            .buttonStyle(ChromeRoundButtonStyle())
            .accessibilityLabel("Menus")
            .accessibilityIdentifier("menus-button")
    }

    /// The options button: opens the window's settings sheet.
    private var windowMenu: some View {
        Button { showsSettings = true } label: { Image(systemName: "ellipsis") }
            .buttonStyle(ChromeRoundButtonStyle())
            .accessibilityLabel("Window options")
            .accessibilityIdentifier("window-menu")
    }

    // MARK: Actions

    /// Closes the iPad window (destroying its scene), or on iPhone goes back to the launcher.
    private func closeScene() {
        if let phone {
            phone.showLauncher()
        } else if !SceneRegistry.shared.destroy(model.sceneID) {
            dismissWindow(id: AppModeScene.id, value: role)
        }
    }

    private func perform(_ action: RemoteWindowAction) {
        switch action {
        case .close:
            closeScene()
        case .reopen:
            model.connection?.reopen(scene: model.sceneID)
        case .openDesktop:
            if phone == nil {
                openWindow(id: AppModeScene.id, value: SceneRole.computerDesktop(computerID: computerID))
            } else {
                phone?.desktopComputerID = computerID
            }
        case .pairAgain:
            pairing = computers.saved.first { $0.id == computerID }
        case .retry:
            model.connection?.retry()
        }
    }
}

/// The message over (or instead of) a window, with its buttons.
@available(iOS 26, *)
struct RemoteWindowOverlayView: View {
    let overlay: RemoteWindowOverlay
    let perform: (RemoteWindowAction) -> Void

    private var symbol: String {
        switch overlay {
        case .connecting, .reconnecting, .lookingForWindow, .waitingForFirstFrame: "arrow.triangle.2.circlepath"
        case .windowClosed, .appQuit: "macwindow.badge.plus"
        case .macLocked: "lock.fill"
        case .permissionMissing: "hand.raised.fill"
        case .versionMismatch: "arrow.down.app"
        case .deviceRevoked, .identityChanged, .denied: "exclamationmark.shield"
        case .replaced, .connectionLost: "wifi.exclamationmark"
        case .waitingForNetwork: "wifi.slash"
        case .tailscaleNotConnected, .tailscaleTurnedOff: "network.slash"
        }
    }

    private var isBusy: Bool {
        switch overlay {
        case .connecting, .reconnecting, .lookingForWindow, .waitingForFirstFrame: true
        default: false
        }
    }

    var body: some View {
        ZStack {
            if overlay.coversWindow { Color.black.opacity(0.78).ignoresSafeArea() } else { Color.black.opacity(0.25).ignoresSafeArea() }
            VStack(spacing: 14) {
                if isBusy { ProgressView().controlSize(.large) } else { Image(systemName: symbol).font(.system(size: 38)).foregroundStyle(Theme.onChromeSecondary) }
                Text(overlay.title).font(.headline).multilineTextAlignment(.center)
                if let message = overlay.message {
                    Text(message).font(.subheadline).foregroundStyle(Theme.onChromeSecondary).multilineTextAlignment(.center)
                }
                HStack(spacing: 12) {
                    ForEach(overlay.actions, id: \.self) { action in
                        if action == overlay.actions.first {
                            Button(action.title) { perform(action) }.buttonStyle(.borderedProminent).tapHaptic()
                        } else {
                            Button(action.title) { perform(action) }.buttonStyle(.bordered).tapHaptic()
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 380)
            .foregroundStyle(Theme.onChrome)
            .chromeCard()
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("window-status")
        }
    }
}

extension RemoteWindowAction: Hashable {}

/// Bridges `AppWindowView` into SwiftUI.
@available(iOS 26, *)
struct AppWindowRepresentable: UIViewRepresentable {
    let model: RemoteWindowSceneModel
    let acceptsInput: Bool

    func makeUIView(context: Context) -> AppWindowView {
        let view = AppWindowView(frame: .zero, device: nil)
        view.onIntents = { [model] intents in model.send(intents) }
        view.onViewPixelSize = { [model] size in model.viewPixelSizeChanged(size) }
        model.view = view
        return view
    }

    func updateUIView(_ view: AppWindowView, context: Context) {
        view.fitMode = model.fitMode
        view.acceptsRemoteInput = acceptsInput
        view.isSoftwareKeyboardVisible = model.isKeyboardVisible
        let window = model.boundWindow
        view.stream = window.flatMap { model.connection?.stream(for: $0) }
    }
}
