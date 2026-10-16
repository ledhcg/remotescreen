import ConnectionKit
import LinkProtocol
import SessionKit
import SwiftUI
import WindowKit

/// The launcher scene of one Mac: its running apps (with window counts), recent apps and all installed apps, with search. Tapping an
/// app launches or activates it and shows its windows, one iPad scene per window (or tabs in one scene, see the settings).
@available(iOS 26, *)
struct LauncherView: View {
    let computerID: UUID
    @Environment(LinkSessionRegistry.self) private var registry
    @Environment(\.openWindow) private var openWindow
    @Environment(\.displayScale) private var displayScale
    @Environment(PhoneNavigation.self) private var phone: PhoneNavigation?
    @Environment(\.leaveAppMode) private var leaveAppMode
    @State private var connection: AppModeConnection?
    @State private var query = ""
    @State private var showsSettings = false

    private var opener: AppModeOpener {
        AppModeOpener(computerID: computerID, openWindow: openWindow, showHere: phone.map { phone in
            { window in if let connection { phone.show(window, in: connection, computerID: computerID) } }
        })
    }

    var body: some View {
        NavigationStack {
            Group {
                if let connection {
                    content(connection)
                } else {
                    ProgressView()
                }
            }
            .navigationTitle(connection?.macName ?? String(localized: "App Mode"))
            .toolbar {
                if let leave = leaveAppMode {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Computers", systemImage: "chevron.backward") { leave() }
                            .accessibilityIdentifier("launcher-leave")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Settings", systemImage: "gearshape") { showsSettings = true }
                        .accessibilityIdentifier("launcher-settings")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Show on full desktop", systemImage: "display") { showDesktop() }
                        .accessibilityIdentifier("launcher-desktop")
                }
            }
        }
        .accessibilityIdentifier("launcher")
        .sheet(isPresented: $showsSettings) { AppModePreferencesView() }
        .onAppear {
            if connection == nil { connection = registry.acquireConnection(computerID: computerID) }
        }
        .onDisappear {
            guard connection != nil else { return }
            connection = nil
            registry.release(computerID: computerID)
        }
    }

    @ViewBuilder
    private func content(_ connection: AppModeConnection) -> some View {
        let status = RemoteWindowStatus.present(
            connection: connection.phase, binding: nil, workspace: connection.workspace, helper: connection.helper, hasFrame: false
        )
        if connection.phase != .connected, let overlay = status.overlay {
            VStack(spacing: 12) {
                ProgressView()
                Text(overlay.title).font(.headline)
                if let message = overlay.message { Text(message).foregroundStyle(.secondary) }
                Button("Try again") { connection.retry() }
            }
            .padding()
            .accessibilityIdentifier("launcher-status")
        } else {
            list(connection)
        }
    }

    private func list(_ connection: AppModeConnection) -> some View {
        let listing = LauncherListing.build(
            directory: connection.directory, workspace: connection.workspace, badges: connection.newWindows.badges, query: query)
        let permissionHints = RemoteWindowOverlay.permissionHints(connection.helper)
        return List {
            if !permissionHints.isEmpty {
                // Without these the Mac's windows can be neither listed nor streamed; say so instead of showing "0 windows".
                Section {
                    Label {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Screon Helper needs permission on the Mac").font(.headline)
                            ForEach(permissionHints, id: \.self) { Text($0).font(.subheadline).foregroundStyle(.secondary) }
                        }
                    } icon: {
                        Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
                    }
                    .accessibilityIdentifier("launcher-permissions")
                }
            }
            ForEach(listing.sections, id: \.section) { section in
                Section(section.section.title) {
                    ForEach(section.entries) { entry in
                        row(entry, connection: connection)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: Text("Search apps"))
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .overlay {
            if listing.isEmpty {
                if query.isEmpty {
                    ContentUnavailableView("No apps", systemImage: "square.grid.2x2", description: Text("Open an app on the Mac to see it here."))
                } else {
                    ContentUnavailableView.search(text: query)
                }
            }
        }
        .task(id: connection.phase) {
            guard connection.phase == .connected else { return }
            connection.requestApps(.recent)
            connection.requestApps(.installed)
        }
        .onChange(of: connection.newWindows.toOpen) { _, _ in opener.openNewWindows(of: connection) }
        .accessibilityIdentifier("launcher-list")
    }

    private func row(_ entry: LauncherEntry, connection: AppModeConnection) -> some View {
        Button {
            opener.open(app: entry.app.bundleID, in: connection)
        } label: {
            HStack(spacing: 12) {
                AppIconView(app: entry.app, store: connection.icons, scale: displayScale)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.app.name).font(.body)
                    if entry.isRunning {
                        Text(windowCountText(entry.windowCount)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if entry.badge > 0 {
                    Text("\(entry.badge)")
                        .font(.caption.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Color.accentColor, in: Capsule())
                        .accessibilityLabel(Text("\(entry.badge) new windows"))
                }
            }
        }
        .accessibilityIdentifier("app-row-\(entry.app.bundleID)")
        .contextMenu {
            Button("Open", systemImage: "macwindow") { opener.open(app: entry.app.bundleID, in: connection) }
            if entry.isRunning {
                Button("Quit", systemImage: "power", role: .destructive) { connection.quitApp(bundleID: entry.app.bundleID) }
            } else {
                Button("Launch", systemImage: "play") { opener.open(app: entry.app.bundleID, in: connection) }
            }
        }
    }

    private func windowCountText(_ count: Int) -> String {
        count == 1 ? String(localized: "1 window") : String(localized: "\(count) windows")
    }

    private func showDesktop() {
        if let phone {
            phone.desktopComputerID = computerID
        } else {
            openWindow(id: AppModeScene.id, value: SceneRole.computerDesktop(computerID: computerID))
        }
    }
}

/// An app icon from the cache, with a placeholder until it arrives.
@available(iOS 26, *)
struct AppIconView: View {
    let app: LinkAppInfo
    let store: AppIconStore
    let scale: Double
    private let points: Double = 40

    var body: some View {
        Group {
            if let image = store.image(for: app, points: points, scale: scale) {
                Image(uiImage: image).resizable().interpolation(.high)
            } else {
                RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.quaternary)
            }
        }
        .frame(width: points, height: points)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .accessibilityHidden(true)
    }
}

/// Settings of App Mode: how windows open, what new windows do, and what ⌘W does.
@available(iOS 26, *)
struct AppModePreferencesView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(AppModePreferences.openStyleKey) private var openStyle = AppOpenStyle.separateWindows.rawValue
    @AppStorage(AppModePreferences.newWindowPolicyKey) private var newWindowPolicy = NewWindowPolicy.autoOpen.rawValue
    @AppStorage(AppModePreferences.closeShortcutKey) private var closeShortcut = CloseShortcutPolicy.closeIPadWindow.rawValue

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Opening an app shows its windows as", selection: $openStyle) {
                        ForEach(AppOpenStyle.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
                    }
                    .accessibilityIdentifier("setting-open-style")
                }
                Section("New windows on the Mac") {
                    Picker("A new window", selection: $newWindowPolicy) {
                        ForEach(NewWindowPolicy.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
                    }
                    .accessibilityIdentifier("setting-new-window")
                }
                Section {
                    Picker("⌘W", selection: $closeShortcut) {
                        ForEach(CloseShortcutPolicy.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
                    }
                    .accessibilityIdentifier("setting-close-shortcut")
                } footer: {
                    Text("Other shortcuts of the Mac app are sent to the Mac. ⌘H, ⌘Space and ⌘Tab stay with the iPad.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

/// iPhone: the list of windows to switch to, and the way back to the apps.
@available(iOS 26, *)
struct WindowSwitcherSheet: View {
    let connection: AppModeConnection
    let computerID: UUID
    let current: WindowID?
    let phone: PhoneNavigation
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let items = WindowSwitcher.items(workspace: connection.workspace, current: current, bindings: connection.bindings, thisScene: nil)
        NavigationStack {
            List {
                Section {
                    Button("Apps", systemImage: "square.grid.2x2") { phone.showLauncher() }
                        .accessibilityIdentifier("switcher-apps")
                }
                Section("Windows") {
                    ForEach(items) { item in
                        Button {
                            phone.show(item.id, in: connection, computerID: computerID)
                        } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(item.title.isEmpty ? item.appName : item.title)
                                    if !item.title.isEmpty { Text(item.appName).font(.caption).foregroundStyle(.secondary) }
                                }
                                Spacer()
                                if item.isCurrent { Image(systemName: "checkmark") }
                            }
                        }
                        .accessibilityIdentifier("switcher-window-\(item.id.rawValue)")
                    }
                }
            }
            .navigationTitle("Windows")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
        .accessibilityIdentifier("window-switcher")
    }
}

/// iPhone: App Mode in the single scene. Shows the launcher, or one Mac window with a button for the switcher.
@available(iOS 26, *)
struct PhoneAppModeView: View {
    let computerID: UUID
    @Environment(ConnectionsModel.self) private var computers
    @State private var phone = PhoneNavigation()

    var body: some View {
        Group {
            if let ref = phone.windowRef {
                RemoteWindowSceneView(role: .remoteWindow(computerID: computerID, windowRef: ref), computerID: computerID, windowRef: ref)
                    .id(ref)
            } else {
                LauncherView(computerID: computerID)
            }
        }
        .environment(phone)
        .fullScreenCover(item: Binding(get: { phone.desktopComputerID.map(IdentifiedID.init) }, set: { phone.desktopComputerID = $0?.id })) { item in
            RootView(model: computers, autoConnect: computers.saved.first { $0.id == item.id })
                .overlay(alignment: .topLeading) {
                    Button("Done", systemImage: "xmark.circle.fill") { phone.desktopComputerID = nil }
                        .labelStyle(.iconOnly)
                        .font(.title2)
                        .padding()
                        .accessibilityIdentifier("desktop-done")
                }
        }
    }

    struct IdentifiedID: Identifiable { let id: UUID }
}

/// iPhone: shows App Mode full screen over the list of computers.
struct PhoneAppModeCover: ViewModifier {
    @Binding var computer: SavedConnection?
    @Environment(LinkSessionRegistry.self) private var registry
    @Environment(ConnectionsModel.self) private var model

    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content.fullScreenCover(item: $computer) { computer in
                PhoneAppModeView(computerID: computer.id)
                    .environment(model)
                    .environment(registry)
                    .environment(\.leaveAppMode, { self.computer = nil })
            }
        } else {
            content
        }
    }
}

private struct LeaveAppModeKey: EnvironmentKey {
    static let defaultValue: (@MainActor () -> Void)? = nil
}

extension EnvironmentValues {
    /// Set on iPhone, where App Mode covers the list of computers: leaves App Mode.
    var leaveAppMode: (@MainActor () -> Void)? {
        get { self[LeaveAppModeKey.self] }
        set { self[LeaveAppModeKey.self] = newValue }
    }
}
