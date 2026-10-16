import ConnectionKit
import InputKit
import RemoteDisplay
import SessionKit
import SwiftUI

#if DEBUG
/// Hands the environment auto-connect to exactly one scene per launch.
@MainActor
enum DebugAutoConnect {
    private static var claimed = false

    static func claim() -> Bool {
        defer { claimed = true }
        return !claimed
    }
}
#endif

struct RootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(LinkSessionRegistry.self) private var linkSessions
    @Environment(\.openWindow) private var openWindow
    @State private var controller = SessionController(defaults: SessionController.environmentDefaults())
    let model: ConnectionsModel
    /// Connect to this computer with its saved password as soon as the view appears (opened from an App Mode window to unlock the Mac).
    var autoConnect: SavedConnection?

    var body: some View {
        Group {
            switch controller.state {
            // Both states share one branch so SessionView (and the last frame) is not rebuilt when the connection drops and comes back.
            case .connected(let name), .reconnecting(let name, _, _):
                SessionView(controller: controller, name: name)
            default:
                ConnectionView(controller: controller, model: model)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background: controller.appDidEnterBackground()
            case .active: controller.appDidBecomeActive()
            case .inactive: controller.sceneDidDeactivate()
            @unknown default: break
            }
        }
        .task {
            if let saved = autoConnect, let password = model.password(for: saved), controller.state == .idle {
                controller.connect(target: saved.target, username: saved.username, password: password) { model.markUsed(saved) }
            }
            #if DEBUG
            // App Mode test hooks: LINK_HOST, LINK_PORT, LINK_PAIRING. First scene only.
            if #available(iOS 26, *), DebugLinkHooks.claim() {
                await DebugLinkHooks.run(model: model, registry: linkSessions) { role in
                    openWindow(id: AppModeScene.id, value: role)
                }
            }
            #endif
            #if DEBUG
            // Auto-connect for test runs: environment variables RFB_HOST, RFB_PORT, RFB_USER, RFB_PASSWORD.
            let environment = ProcessInfo.processInfo.environment
            // Only the first scene connects: a window opened later must not start a second session.
            if let host = environment["RFB_HOST"], DebugAutoConnect.claim() {
                let port = UInt16(environment["RFB_PORT"] ?? "") ?? 5900
                let username = environment["RFB_USER"] ?? ""
                let password = environment["RFB_PASSWORD"] ?? ""
                let shouldSave = environment["RFB_SAVE"] == "1" // exercise the save-connection flow without typing into the form
                controller.connect(host: host, port: port, username: username, password: password) {
                    guard shouldSave else { return }
                    model.remember(target: .host(host, port: port), username: username, password: password, name: host)
                }
            }
            #endif
        }
    }
}

struct SessionView: View {
    let controller: SessionController
    let name: String
    /// Frames of the floating controls in window coordinates. The remote-screen view ignores touches landing here, so the button
    /// receives the touch instead of it being sent to the Mac.
    @State private var toolbarFrame = CGRect.zero
    @State private var keyBarFrame = CGRect.zero
    @State private var bannerFrame = CGRect.zero
    /// The toolbar collapses into a small pill to make room for the Mac screen (especially on iPhone).
    @State private var isToolbarCollapsed = false

    private var excludedRegions: [CGRect] {
        [toolbarFrame, keyBarFrame, bannerFrame].filter { $0 != .zero }.map { $0.insetBy(dx: -12, dy: -12) }
    }

    private var showsSidebar: Bool { controller.sidebarPosition != .hidden }

    var body: some View {
        // The sidebar sits beside the Mac screen (not on top of it): the Mac screen shrinks to fit the rest, like Sidecar.
        HStack(spacing: 0) {
            if controller.sidebarPosition == .leading { Sidebar(controller: controller, name: name) }
            screenArea
            if controller.sidebarPosition == .trailing { Sidebar(controller: controller, name: name) }
        }
        .background(.black)
        .onChange(of: controller.isKeyBarVisible) { _, visible in
            if !visible { keyBarFrame = .zero } // the old frame must not block touches to the remote screen
        }
    }

    private var screenArea: some View {
        ZStack {
            ScreonRepresentable(controller: controller, excludedRegions: excludedRegions)
                .ignoresSafeArea()
            if case .reconnecting = controller.state {
                // Dim and block touches: there is no session left to receive input.
                Color.black.opacity(0.45)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture {}
            }
            VStack(spacing: 8) {
                toolbar.claimingTouches(frame: $toolbarFrame)
                if controller.isStatsVisible {
                    Text(controller.statsLine)
                        .font(.caption.monospacedDigit())
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.ultraThinMaterial, in: Capsule())
                        .allowsHitTesting(false)
                        .accessibilityIdentifier("stream-stats")
                }
                if let warning = controller.securityWarning {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(.ultraThinMaterial, in: Capsule())
                        .allowsHitTesting(false)
                        .accessibilityIdentifier("security-warning")
                }
                if case .reconnecting(let reconnectName, let attempt, let total) = controller.state {
                    reconnectBanner(name: reconnectName, attempt: attempt, total: total)
                } else if let notice = controller.clipboard.notice {
                    Text(notice)
                        .font(.footnote)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                        .transition(.opacity)
                        .allowsHitTesting(false)
                }
                Spacer()
                if controller.isKeyBarVisible {
                    KeyBar(controller: controller, showsModifiers: !showsSidebar)
                        .claimingTouches(frame: $keyBarFrame)
                        .padding(.bottom, 4)
                }
            }
            .animation(.default, value: controller.clipboard.notice)
        }
    }

    private func reconnectBanner(name: String, attempt: Int, total: Int) -> some View {
        HStack(spacing: 10) {
            ProgressView()
            Text(controller.isApplyingQuality
                 ? String(localized: "Applying the new quality mode…")
                 : String(localized: "Lost connection to \(name). Reconnecting (\(attempt)/\(total))…"))
                .font(.footnote)
            Button("Cancel") { controller.disconnect() }
                .font(.footnote.weight(.semibold))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
        .claimingTouches(frame: $bannerFrame)
        // When the banner disappears its frame must disappear too: `onGeometryChange` does not report when the view is removed, so
        // previously a strip under the toolbar (usually the Mac menu bar) stayed touch-blocked for the rest of the session after each reconnect.
        .onDisappear { bannerFrame = .zero }
    }

    // MARK: - Toolbar

    private var isReconnecting: Bool {
        if case .reconnecting = controller.state { return true }
        return false
    }

    private var statusColor: Color {
        if isReconnecting { return .orange }
        return controller.isViewOnly ? .blue : .green
    }

    private var statusText: String {
        if isReconnecting { return String(localized: "Reconnecting…") }
        return controller.isViewOnly ? String(localized: "View only") : String(localized: "Controlling")
    }

    @ViewBuilder
    private var toolbar: some View {
        if isToolbarCollapsed { collapsedToolbar } else { fullToolbar }
    }

    /// The collapsed pill: tap to bring back the full toolbar.
    private var collapsedToolbar: some View {
        Button {
            withAnimation(.snappy) { isToolbarCollapsed = false }
        } label: {
            HStack(spacing: 6) {
                Circle().fill(statusColor).frame(width: 8, height: 8)
                Text(name).font(.footnote.weight(.semibold)).lineLimit(1)
                Image(systemName: "chevron.down").font(.caption2.weight(.bold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(.ultraThinMaterial, in: Capsule())
        }
        .accessibilityLabel("Show toolbar")
        .accessibilityValue("\(name), \(statusText)")
        .padding(.top, 4)
    }

    /// The floating toolbar, laid out like Screen Sharing's: disconnect, computer name and status, common buttons, then the options menu.
    private var fullToolbar: some View {
        HStack(spacing: 14) {
            // When the sidebar is showing it already has disconnect, keyboard and extra-keys: the toolbar stays compact and covers less of the Mac menu bar.
            if !showsSidebar {
                Button("Disconnect from \(name)", systemImage: "xmark.circle.fill") { controller.disconnect() }
                    .tint(.red)
            }

            Button {
                withAnimation(.snappy) { isToolbarCollapsed = true }
            } label: {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Circle().fill(statusColor).frame(width: 7, height: 7)
                        Text(name).font(.subheadline.weight(.semibold)).lineLimit(1)
                    }
                    Text(statusText).font(.caption2).foregroundStyle(.secondary)
                }
                .frame(maxWidth: 150, alignment: .leading)
                .foregroundStyle(.white)
            }
            .accessibilityLabel(String(localized: "\(name), \(statusText). Tap to collapse the toolbar"))

            Divider().frame(height: 24)

            if !showsSidebar {
                Button("Keyboard", systemImage: "keyboard") { controller.toggleKeyboard() }
                    .tint(controller.isKeyboardVisible ? .blue : .white)
                    .disabled(controller.isViewOnly || !controller.isLive)
                    .accessibilityAddTraits(controller.isKeyboardVisible ? .isSelected : [])
                Button("Extra keys", systemImage: "command") { controller.toggleKeyBar() }
                    .tint(controller.isKeyBarVisible ? .blue : .white)
                    .disabled(controller.isViewOnly || !controller.isLive)
                    .accessibilityAddTraits(controller.isKeyBarVisible ? .isSelected : [])
            }
            optionsMenu
        }
        .labelStyle(.iconOnly)
        .font(.title3)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
        .contentShape(Capsule()) // the whole pill receives the touch, not just the icon
        .padding(.top, 4)
    }

    /// The options menu, grouped like Screen Sharing's menu: control/view only, display size, clipboard, cursor.
    private var optionsMenu: some View {
        Menu {
            Picker("Mode", selection: Binding(get: { controller.isViewOnly }, set: { controller.setViewOnly($0) })) {
                Label("Take control", systemImage: "cursorarrow.click.2").tag(false)
                Label("View only", systemImage: "eye").tag(true)
            }
            .pickerStyle(.inline)

            Picker("Display", selection: Binding(get: { controller.displayMode }, set: { controller.setDisplayMode($0) })) {
                Label("Fit to screen", systemImage: "arrow.down.right.and.arrow.up.left").tag(DisplayMode.fit)
                Label("Fill screen", systemImage: "arrow.up.left.and.arrow.down.right").tag(DisplayMode.fill)
                Label("Native pixels (1:1)", systemImage: "1.square").tag(DisplayMode.native)
                Label("Match device resolution", systemImage: "rectangle.on.rectangle").tag(DisplayMode.device)
            }
            .pickerStyle(.inline)

            Picker("Touch style", selection: Binding(get: { controller.touchMode }, set: { controller.setTouchMode($0) })) {
                Label("Direct touch", systemImage: "hand.point.up.left").tag(TouchMode.directTouch)
                Label("Trackpad", systemImage: "rectangle.and.hand.point.up.left").tag(TouchMode.trackpad)
            }
            .pickerStyle(.inline)

            Picker("Sidebar", selection: Binding(get: { controller.sidebarPosition }, set: { controller.setSidebarPosition($0) })) {
                Label("Sidebar on the left", systemImage: "sidebar.left").tag(SidebarPosition.leading)
                Label("Sidebar on the right", systemImage: "sidebar.right").tag(SidebarPosition.trailing)
                Label("Hide sidebar", systemImage: "rectangle").tag(SidebarPosition.hidden)
            }
            .pickerStyle(.inline)

            Menu("Gestures on Mac", systemImage: "hand.draw") {
                Toggle("Smooth trackpad-style scrolling", isOn: Binding(
                    get: { controller.smoothScroll }, set: { controller.setSmoothScroll($0) }
                ))
                Picker("Two-finger pinch/rotate", selection: Binding(
                    get: { controller.pinchSendsToMac }, set: { controller.setPinchSendsToMac($0) }
                )) {
                    Text("Zoom the iPad view").tag(false)
                    Text("Send to Mac").tag(true)
                }
                .pickerStyle(.inline)
                if !controller.isAppleServer {
                    Text("Only available with a Mac (macOS Screen Sharing)")
                }
            }

            if UIDevice.current.userInterfaceIdiom == .pad {
                Menu("Apple Pencil", systemImage: "applepencil") {
                    Picker("Pencil double tap", selection: Binding(
                        get: { controller.pencilDoubleTapAction }, set: { controller.setPencilDoubleTapAction($0) }
                    )) {
                        Text("Right-click").tag(PencilDoubleTapAction.secondaryClick)
                        Text("Show/hide keyboard").tag(PencilDoubleTapAction.toggleKeyboard)
                        Text("Do nothing").tag(PencilDoubleTapAction.nothing)
                    }
                    .pickerStyle(.inline)
                    Toggle("Fingers scroll only when using the pencil", isOn: Binding(
                        get: { controller.fingersOnlyScrollWithPencil }, set: { controller.setFingersOnlyScrollWithPencil($0) }
                    ))
                }
            }

            Toggle("Show Mac cursor", systemImage: "cursorarrow", isOn: Binding(
                get: { controller.isRemoteCursorVisible }, set: { controller.setRemoteCursorVisible($0) }
            ))

            Picker("Picture quality", selection: Binding(get: { controller.qualityMode }, set: { controller.setQualityMode($0) })) {
                Label("Automatic", systemImage: "wand.and.stars").tag(QualityMode.adaptive)
                Label("Best quality", systemImage: "sparkles.tv").tag(QualityMode.bestQuality)
                Label("Best performance", systemImage: "bolt").tag(QualityMode.bestPerformance)
            }
            .pickerStyle(.menu)

            Toggle("Show stream statistics", systemImage: "gauge.with.dots.needle.33percent", isOn: Binding(
                get: { controller.isStatsVisible }, set: { controller.setStatsVisible($0) }
            ))

            Menu("Clipboard", systemImage: "doc.on.clipboard") {
                Button("Get clipboard from Mac", systemImage: "arrow.down.doc") { controller.clipboard.requestFromMac() }
                Picker("Sync", selection: Binding(get: { controller.clipboard.mode }, set: { controller.clipboard.mode = $0 })) {
                    Text("Manual").tag(ClipboardBridge.Mode.manual)
                    Text("Automatic (⌘C, ⌘V)").tag(ClipboardBridge.Mode.shared)
                }
                .pickerStyle(.inline)
            }

            Section {
                Button("Disconnect", systemImage: "xmark.circle", role: .destructive) { controller.disconnect() }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .tint(.white)
        .accessibilityLabel("Options")
    }
}

/// The extra-keys bar: keys iOS lacks on the on-screen keyboard. Modifier keys (⌃ ⌥ ⌘ ⇧) are sticky: tap once to hold down,
/// it releases itself after the next key or click, so tapping ⌘ then typing `c` is Cmd+C. Double-tap quickly to lock, tap again to release.
/// When the sidebar is showing, the modifier keys live only on the sidebar.
struct KeyBar: View {
    let controller: SessionController
    var showsModifiers = true

    private static let modifiers: [(StickyModifier, String, String)] = [
        (.control, "⌃", "Control"), (.option, "⌥", "Option"), (.command, "⌘", "Command"), (.shift, "⇧", "Shift"),
    ]
    private static let keys: [(VirtualKey, String, String)] = [
        (.escape, "esc", "Escape"), (.tab, "tab", "Tab"),
        (.left, "←", String(localized: "Left arrow")), (.down, "↓", String(localized: "Down arrow")), (.up, "↑", String(localized: "Up arrow")), (.right, "→", String(localized: "Right arrow")),
        (.home, "home", "Home"), (.end, "end", "End"), (.pageUp, "pg↑", "Page Up"), (.pageDown, "pg↓", "Page Down"),
        (.forwardDelete, "del", String(localized: "Forward Delete")),
    ]

    /// Clipboard: choose the mode, fetch from the Mac, and the system Paste button to send to the Mac (this button reads the device
    /// clipboard without showing the permission prompt, unlike the app reading it itself).
    private var clipboardControls: some View {
        HStack(spacing: 6) {
            Menu {
                Picker("Clipboard sync", selection: Binding(
                    get: { controller.clipboard.mode }, set: { controller.clipboard.mode = $0 }
                )) {
                    Text("Manual").tag(ClipboardBridge.Mode.manual)
                    Text("Automatic (⌘C, ⌘V)").tag(ClipboardBridge.Mode.shared)
                }
            } label: {
                Image(systemName: controller.clipboard.mode == .shared ? "doc.on.clipboard.fill" : "doc.on.clipboard")
                    .frame(minWidth: 28)
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("Clipboard mode")

            Button { controller.clipboard.requestFromMac() } label: {
                Image(systemName: "arrow.down.doc").frame(minWidth: 28)
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("Get clipboard from Mac")

            PasteButton(payloadType: String.self) { strings in
                controller.clipboard.send(text: strings.first ?? "")
            }
            .labelStyle(.iconOnly)
            .buttonBorderShape(.roundedRectangle)
            .accessibilityLabel("Send clipboard to Mac")
        }
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                if showsModifiers {
                    ForEach(Self.modifiers, id: \.0) { modifier, symbol, name in
                        let state = controller.modifierStates[modifier] ?? .up
                        Button { controller.toggleModifier(modifier) } label: {
                            HStack(spacing: 2) {
                                Text(symbol)
                                if state == .locked { Image(systemName: "lock.fill").font(.system(size: 8, weight: .bold)) }
                            }
                            .frame(minWidth: 28)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(state == .up ? .gray : .blue)
                        .accessibilityLabel(name)
                        .accessibilityValue(state == .locked ? String(localized: "Locked") : "")
                        .accessibilityAddTraits(state == .up ? [] : .isSelected)
                    }
                    Divider().frame(height: 24)
                }
                clipboardControls
                Divider().frame(height: 24)
                ForEach(Self.keys, id: \.0) { key, symbol, name in
                    Button { controller.press(key) } label: {
                        Text(symbol).frame(minWidth: 28)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel(name)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .fixedSize(horizontal: false, vertical: true)
        // While reconnecting, a tapped sticky key would be dropped (no session) yet still show as sticky: disable the whole bar until reconnected.
        .disabled(!controller.isLive)
        .background(.ultraThinMaterial, in: Capsule())
        .contentShape(Capsule())
        .padding(.horizontal, 12)
    }
}

private extension View {
    /// Lets this floating control receive its own touches and reports its frame outward (so the remote-screen view ignores that region).
    ///
    /// Do not remove `simultaneousGesture`: a SwiftUI button overlaid on a UIViewRepresentable (the remote-screen view) does not
    /// receive touches unless that region has some SwiftUI gesture. Measured on a real iPad (iPadOS 27.0.1): without it, pressing
    /// the button does nothing, even with the touch region excluded from the view underneath. This empty gesture does nothing; it only
    /// makes SwiftUI claim the region.
    func claimingTouches(frame: Binding<CGRect>) -> some View {
        simultaneousGesture(TapGesture().onEnded {})
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame.wrappedValue = $0 }
    }
}

struct ScreonRepresentable: UIViewRepresentable {
    let controller: SessionController
    var excludedRegions: [CGRect] = []

    func makeUIView(context: Context) -> ScreonView {
        let view = ScreonView(frame: .zero, device: nil)
        controller.attach(view)
        return view
    }

    func updateUIView(_ uiView: ScreonView, context: Context) {
        uiView.excludedRegions = excludedRegions
    }
}
