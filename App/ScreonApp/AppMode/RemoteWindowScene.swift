import ConnectionKit
import InputKit
import LinkProtocol
import RemoteDisplay
import SessionKit
import SwiftUI
import UIKit
import WindowKit

/// State of one remote-window scene: which window it shows, its input encoder, and the debounced stream size.
@available(iOS 26, *)
@MainActor
@Observable
final class RemoteWindowSceneModel {
    let computerID: UUID
    let requestedWindow: WindowID?
    let sceneID = SceneID(UUID().uuidString)

    private(set) var connection: AppModeConnection?
    var fitMode: WindowFitMode = .fit
    var isKeyboardVisible = false

    @ObservationIgnored weak var view: AppWindowView?
    @ObservationIgnored private var encoder: LinkInputEncoder?
    @ObservationIgnored private var subscribedWindow: WindowID?
    @ObservationIgnored private var pixelSize: CGSize = .zero
    @ObservationIgnored private var resizeTask: Task<Void, Never>?
    @ObservationIgnored private var isPaused = false

    init(computerID: UUID, windowRef: String) {
        self.computerID = computerID
        requestedWindow = UInt32(windowRef).map { WindowID(rawValue: $0) }
    }

    // MARK: Lifecycle

    func start(registry: LinkSessionRegistry) {
        guard connection == nil, let connection = registry.acquireConnection(computerID: computerID) else { return }
        self.connection = connection
        if let requestedWindow { connection.attach(scene: sceneID, window: requestedWindow) }
    }

    func stop(registry: LinkSessionRegistry) {
        guard let connection else { return }
        resizeTask?.cancel()
        connection.detach(scene: sceneID)
        self.connection = nil
        subscribedWindow = nil
        registry.release(computerID: computerID)
    }

    /// The window this scene shows now, once the Mac's snapshot has told which it is.
    var boundWindow: WindowID? { connection?.bindingState(of: sceneID)?.windowID }

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
        let rate = UIScreen.main.maximumFramesPerSecond
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

    // MARK: Focus

    func scenePhaseChanged(_ phase: ScenePhase) {
        guard let connection else { return }
        switch phase {
        case .background:
            isPaused = true
            view?.releaseAllInput()
            if let window = subscribedWindow { connection.pause(window: window) }
        case .inactive:
            view?.releaseAllInput()
        case .active:
            connection.appDidBecomeActive()
            if isPaused {
                isPaused = false
                if let window = subscribedWindow { connection.resume(window: window) } else { syncSubscription() }
            }
        @unknown default:
            break
        }
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
    @State private var model: RemoteWindowSceneModel
    @State private var pairing: SavedConnection?

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
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                        .accessibilityIdentifier("secure-input-banner")
                }
                Spacer()
            }
            .padding(.top, 8)
            .allowsHitTesting(false)
            VStack {
                HStack {
                    Spacer()
                    windowMenu
                }
                Spacer()
            }
            .padding(8)
        }
        .background(.black)
        .onAppear { model.start(registry: registry) }
        .onDisappear { model.stop(registry: registry) }
        .onChange(of: model.boundWindow) { _, _ in model.syncSubscription() }
        .onChange(of: scenePhase) { _, phase in model.scenePhaseChanged(phase) }
        .sheet(item: $pairing) { computer in
            AppModePairingView(computer: computer, model: computers) {
                pairing = nil
                model.connection?.retry()
            }
        }
    }

    private var windowMenu: some View {
        Menu {
            Picker("Fit", selection: Bindable(model).fitMode) {
                Text("Fit").tag(WindowFitMode.fit)
                Text("Fill").tag(WindowFitMode.fill)
                Text("Actual size").tag(WindowFitMode.actual)
            }
            Button("Reset zoom", systemImage: "arrow.up.left.and.down.right.magnifyingglass") { model.view?.resetZoom() }
            Toggle("Keyboard", systemImage: "keyboard", isOn: Bindable(model).isKeyboardVisible)
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.title3)
                .padding(8)
                .background(.ultraThinMaterial, in: Circle())
        }
        .accessibilityLabel("Window options")
        .accessibilityIdentifier("window-menu")
    }

    private func perform(_ action: RemoteWindowAction) {
        switch action {
        case .close:
            dismissWindow(id: AppModeScene.id, value: role)
        case .reopen:
            model.connection?.reopen(scene: model.sceneID)
        case .openDesktop:
            openWindow(id: AppModeScene.id, value: SceneRole.computerDesktop(computerID: computerID))
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
                if isBusy { ProgressView().controlSize(.large) } else { Image(systemName: symbol).font(.system(size: 38)).foregroundStyle(.secondary) }
                Text(overlay.title).font(.headline).multilineTextAlignment(.center)
                if let message = overlay.message {
                    Text(message).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                HStack(spacing: 12) {
                    ForEach(overlay.actions, id: \.self) { action in
                        if action == overlay.actions.first {
                            Button(action.title) { perform(action) }.buttonStyle(.borderedProminent)
                        } else {
                            Button(action.title) { perform(action) }.buttonStyle(.bordered)
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 380)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
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
