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
    /// Shown full screen over App Mode (iPhone): closes the cover. Offered as a Done button while not in a session, and called when the user
    /// disconnects from the session. Inside a session the toolbar's Disconnect does the job: a separate button floating over the Mac screen
    /// sat on the toolbar and its taps also reached the Mac.
    var onClose: (() -> Void)?

    private static func isInSession(_ state: SessionController.State) -> Bool {
        switch state {
        case .connected, .reconnecting: true
        default: false
        }
    }

    var body: some View {
        Group {
            switch controller.state {
            // Both states share one branch so SessionView (and the last frame) is not rebuilt when the connection drops and comes back.
            case .connected(let name), .reconnecting(let name, _, _):
                SessionView(controller: controller, name: name)
            default:
                ConnectionView(controller: controller, model: model)
                    .overlay(alignment: .topLeading) {
                        if let onClose {
                            Button("Done", systemImage: "xmark.circle.fill", action: onClose)
                                .labelStyle(.iconOnly)
                                .font(.title2)
                                .frame(minWidth: 44, minHeight: 44)
                                .contentShape(Rectangle())
                                .padding(.horizontal, 8)
                                .accessibilityIdentifier("desktop-done")
                        }
                    }
            }
        }
        .onChange(of: controller.state) { old, new in
            if let onClose, Self.isInSession(old), new == .idle { onClose() } // disconnected from the toolbar: leave the cover
        }
        // Closing this window (app switcher, Stage Manager) releases the view but not the connection loop, which holds the controller:
        // without this the session kept running, decoding frames for nothing and reconnecting on its own.
        .onDisappear { controller.disconnect() }
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
    @State private var showsSettings = false

    private var excludedRegions: [CGRect] {
        [toolbarFrame, keyBarFrame, bannerFrame].filter { $0 != .zero }.map { $0.insetBy(dx: -12, dy: -12) }
    }

    /// The toolbar floats at the top centre. DEBUG UI tests can move it with `SCREON_TOOLBAR_ALIGN=trailing`: XCUITest's `twoFingerTap()`
    /// puts its two fingers on the vertical centre line at the very top and bottom of the screen view, and on an iPad the top finger
    /// lands on the centred toolbar, so the view never sees a second touch.
    private static var toolbarAlignment: Alignment {
        #if DEBUG
        if ProcessInfo.processInfo.environment["SCREON_TOOLBAR_ALIGN"] == "trailing" { return .trailing }
        #endif
        return .center
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
        // The Mac screen gets the status bar's room (it used to sit over the Mac menu bar); the home indicator fades while idle.
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        // The controls float over a black letterbox: the whole window is dark for the session, so the system's menus and alerts are too
        // (`.environment(\.colorScheme)` would only darken SwiftUI views, and a menu would open light over the dark bar).
        .preferredColorScheme(.dark)
        .onChange(of: controller.isKeyBarVisible) { _, visible in
            if !visible { keyBarFrame = .zero } // the old frame must not block touches to the remote screen
        }
        .sheet(isPresented: $showsSettings) {
            SessionSettingsSheet(controller: controller, name: name)
                .presentationDetents([.medium, .large])
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
                    .frame(maxWidth: .infinity, alignment: Self.toolbarAlignment)
                if controller.isStatsVisible {
                    Text(controller.statsLine)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Theme.onChrome)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .chromePill()
                        .allowsHitTesting(false)
                        .accessibilityIdentifier("stream-stats")
                }
                if !NetworkMonitor.shared.snapshot.isOnline, controller.isLive {
                    // The session cannot work without a network; say so before the connection itself notices.
                    Label("No internet connection", systemImage: "wifi.slash")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .chromeBanner()
                        .allowsHitTesting(false)
                        .accessibilityIdentifier("offline-banner")
                }
                if let warning = controller.securityWarning {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .chromeBanner()
                        .allowsHitTesting(false)
                        .accessibilityIdentifier("security-warning")
                }
                if case .reconnecting(let reconnectName, let attempt, let total) = controller.state {
                    reconnectBanner(name: reconnectName, attempt: attempt, total: total)
                } else if let notice = controller.clipboard.notice {
                    Text(notice)
                        .font(.footnote)
                        .foregroundStyle(Theme.onChrome)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .chromeBanner()
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
                 : controller.isWaitingForNetwork
                 ? String(localized: "No internet connection. Screon reconnects to \(name) when the network is back.")
                 : String(localized: "Lost connection to \(name). Reconnecting (\(attempt)/\(total))…"))
                .font(.footnote)
            Button("Cancel") { controller.disconnect() }
                .font(.footnote.weight(.semibold))
        }
        .foregroundStyle(Theme.onChrome)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .chromeBanner()
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
        return controller.isViewOnly ? Theme.accent : Theme.online
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
            .foregroundStyle(Theme.onChrome)
            .padding(.horizontal, 14)
            .frame(minHeight: Theme.Size.hit)
            .chromePill()
            .contentShape(Capsule())
        }
        .accessibilityLabel("Show toolbar")
        .accessibilityValue("\(name), \(statusText)")
        .padding(.top, 4)
    }

    /// The floating toolbar, laid out like Screen Sharing's: disconnect, computer name and status, common buttons, then the options menu.
    /// Every button is a round chrome button; the keyboard and extra-keys buttons fill with the accent while they are on.
    private var fullToolbar: some View {
        HStack(spacing: 8) {
            // When the sidebar is showing it already has disconnect, keyboard and extra-keys: the toolbar stays compact and covers less of the Mac menu bar.
            if !showsSidebar {
                Button { controller.disconnect() } label: { Image(systemName: "xmark") }
                    .buttonStyle(ChromeRoundButtonStyle(isDestructive: true))
                    .accessibilityLabel("Disconnect from \(name)")
            }

            Button {
                withAnimation(.snappy) { isToolbarCollapsed = true }
            } label: {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Circle().fill(statusColor).frame(width: 7, height: 7)
                        Text(name).font(.subheadline.weight(.semibold)).lineLimit(1)
                    }
                    Text(statusText).font(.caption2).foregroundStyle(Theme.onChromeSecondary)
                }
                .frame(maxWidth: 110, alignment: .leading)
                .frame(minHeight: Theme.Size.hit)
                .foregroundStyle(Theme.onChrome)
                .contentShape(Rectangle())
            }
            .accessibilityLabel(String(localized: "\(name), \(statusText). Tap to collapse the toolbar"))

            if !showsSidebar {
                Button { controller.toggleKeyboard() } label: { Image(systemName: "keyboard") }
                    .buttonStyle(ChromeRoundButtonStyle(isSelected: controller.isKeyboardVisible))
                    .disabled(controller.isViewOnly || !controller.isLive)
                    .opacity(controller.isViewOnly || !controller.isLive ? 0.4 : 1)
                    .accessibilityLabel("Keyboard")
                    .accessibilityAddTraits(controller.isKeyboardVisible ? .isSelected : [])
                Button { controller.toggleKeyBar() } label: { Image(systemName: "command") }
                    .buttonStyle(ChromeRoundButtonStyle(isSelected: controller.isKeyBarVisible))
                    .disabled(controller.isViewOnly || !controller.isLive)
                    .opacity(controller.isViewOnly || !controller.isLive ? 0.4 : 1)
                    .accessibilityLabel("Extra keys")
                    .accessibilityAddTraits(controller.isKeyBarVisible ? .isSelected : [])
            }
            optionsButton
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .chromePill()
        .contentShape(Capsule()) // the whole pill receives the touch, not just the icon
        .padding(.top, 4)
    }

    /// The options button: opens the settings sheet (icon and title, current value, a menu of the others; Disconnect at the foot).
    private var optionsButton: some View {
        Button { showsSettings = true } label: { Image(systemName: "ellipsis") }
            .buttonStyle(ChromeRoundButtonStyle())
            .accessibilityLabel("Options")
            .accessibilityIdentifier("options-button")
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
                // A menu is not a `Button`, so it cannot take a button style: `KeyCapLabel` is the same cap. Automatic sync is a state,
                // so the key fills with the accent while it is on (the icon stays the same one as the other keys').
                KeyCapLabel(systemImage: "doc.on.clipboard", isSelected: controller.clipboard.mode == .shared)
            }
            .accessibilityLabel("Clipboard mode")
            .selectionHaptic(controller.clipboard.mode)

            Button { controller.clipboard.requestFromMac() } label: { Image(systemName: "arrow.down.doc") }
                .buttonStyle(KeyCapStyle())
                .accessibilityLabel("Get clipboard from Mac")

            // The system's own paste control (it reads the clipboard without the permission prompt): dressed like the other keys. Its
            // icon is the system's, so the cap around it is cut to the key size and filled with the key colour.
            PasteButton(payloadType: String.self) { strings in
                controller.clipboard.send(text: strings.first ?? "")
            }
            .labelStyle(.iconOnly)
            .controlSize(.large)
            .buttonBorderShape(.roundedRectangle(radius: Theme.Radius.key))
            .tint(Theme.chromeRaised)
            .foregroundStyle(Theme.onChrome)
            .scaleEffect(1.3) // the system draws its icon small; scaled up it matches the other keys' icons, and the clip cuts the cap to size
            .frame(width: Theme.Size.key.width, height: Theme.Size.key.height)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.key, style: .continuous))
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
                            ZStack(alignment: .bottomTrailing) {
                                KeyCapText(symbol).frame(maxWidth: .infinity, maxHeight: .infinity)
                                if state == .locked { Image(systemName: "lock.fill").font(.system(size: 8, weight: .bold)).padding(4) }
                            }
                        }
                        .buttonStyle(KeyCapStyle(isSelected: state != .up))
                        .accessibilityLabel(name)
                        .accessibilityValue(state == .locked ? String(localized: "Locked") : "")
                        .accessibilityAddTraits(state == .up ? [] : .isSelected)
                    }
                    Divider().frame(height: 24).overlay(Theme.hairline)
                }
                clipboardControls
                Divider().frame(height: 24).overlay(Theme.hairline)
                ForEach(Self.keys, id: \.0) { key, symbol, name in
                    Button { controller.press(key) } label: { KeyCapText(symbol) }
                        .buttonStyle(KeyCapStyle())
                    .accessibilityLabel(name)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .fixedSize(horizontal: false, vertical: true)
        // While reconnecting, a tapped sticky key would be dropped (no session) yet still show as sticky: disable the whole bar until reconnected.
        .disabled(!controller.isLive)
        .chromePill()
        .clipShape(Capsule()) // keys scrolled to the ends must not stick out past the rounded ends
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
