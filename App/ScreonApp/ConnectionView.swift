import ConnectionKit
import SessionKit
import SwiftUI
import UIKit

/// The computer picker, in the style of Screen Sharing: an address field ("Connect to server"), the list of saved computers,
/// and computers found on the network. Tapping a computer connects (or asks for name and password in a dialog); there is no long form.
struct ConnectionView: View {
    let controller: SessionController
    let model: ConnectionsModel

    @State private var browser = ServiceBrowser()
    @State private var address = ""
    @State private var addressError: String?
    /// The login dialog currently open, if any.
    @State private var login: LoginRequest?
    /// Name of the computer being connected to, shown on the waiting screen.
    @State private var connectingName = ""
    /// Saved computer just connected with its saved password, so on failure we can offer to re-enter the password.
    @State private var lastSaved: SavedConnection?
    @FocusState private var addressFocused: Bool
    @Environment(\.openWindow) private var openWindow
    /// The computer whose App Mode pairing sheet is open.
    @State private var pairingFor: SavedConnection?
    /// The computer whose App Mode streaming settings are open.
    @State private var streamingFor: SavedConnection?
    /// iPhone: the computer whose App Mode is open in this scene (iPhone has one scene, so windows cannot open beside it).
    @State private var phoneAppMode: SavedConnection?
    @State private var showsNetworkSettings = false

    private var sections: ComputerList.Sections {
        ComputerList.sections(saved: model.saved, discovered: browser.hosts)
    }

    private var failureMessage: String? {
        if case .failed(let message) = controller.state { return message }
        return nil
    }

    var body: some View {
        NavigationStack {
            List {
                addressSection
                if !sections.saved.isEmpty {
                    Section("Saved computers") {
                        ForEach(sections.saved) { row in
                            computerButton(row)
                                .swipeActions {
                                    if case .saved(let connection) = row.source {
                                        Button("Delete", role: .destructive) { delete(connection) }
                                    }
                                }
                                .contextMenu { contextMenu(for: row) }
                        }
                    }
                }
                nearbySection
                if sections.isEmpty { helpSection }
                if let saveError = model.lastError {
                    Section { Text("Couldn't save: \(saveError)").foregroundStyle(.red) }
                }
            }
            .navigationTitle("Screon")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Network", systemImage: "network") { showsNetworkSettings = true }
                        .accessibilityIdentifier("network-settings")
                }
                if UIDevice.current.userInterfaceIdiom == .pad {
                    ToolbarItem(placement: .topBarTrailing) { AppPointerMenu() }
                }
            }
            .sheet(isPresented: $showsNetworkSettings) { NetworkSettingsView() }
            .modifier(AppModePairingSheet(computer: $pairingFor, model: model))
            .sheet(item: $streamingFor) { computer in AppModeSettingsView(computer: computer, model: model) }
            .modifier(PhoneAppModeCover(computer: $phoneAppMode))
            .onAppear { browser.start() }
            .onDisappear { browser.stop() }
            .overlay { if controller.state == .connecting && login == nil { connectingCard } }
            .sheet(item: $login, onDismiss: { controller.dismissFailure() }) { request in
                LoginSheet(request: request, controller: controller) { username, password, remember in
                    connect(request, username: username, password: password, remember: remember)
                } onCancel: {
                    controller.disconnect()
                    login = nil
                }
            }
            .alert("Couldn't connect", isPresented: failureAlertShown) {
                if let lastSaved {
                    Button("Re-enter password…") { login = LoginRequest(saved: lastSaved) }
                }
                Button("Close", role: .cancel) {}
            } message: {
                Text(failureMessage ?? "")
            }
        }
    }

    // MARK: - Address field

    private var addressSection: some View {
        Section {
            HStack(spacing: 10) {
                Image(systemName: "network").foregroundStyle(.secondary)
                TextField("Computer name or VNC address", text: $address)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .submitLabel(.go)
                    .focused($addressFocused)
                    .onSubmit(connectToAddress)
                    .accessibilityIdentifier("address-field")
                if !address.isEmpty {
                    Button(action: connectToAddress) {
                        Image(systemName: "arrow.right.circle.fill").font(.title2)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Connect")
                }
            }
        } footer: {
            if let addressError {
                Text(addressError).foregroundStyle(.red)
            } else {
                Text("Examples: mac-mini.local, 192.168.1.5, or vnc://account@host:5900")
            }
        }
    }

    // MARK: - List

    @ViewBuilder
    private var nearbySection: some View {
        if !sections.nearby.isEmpty {
            Section("On the network") {
                ForEach(sections.nearby) { computerButton($0) }
            }
        } else if browser.hosts.isEmpty, !browser.denied, !sections.saved.isEmpty {
            // Saved computers exist: just hint lightly that we are searching, without taking space with the help panel.
            Section("On the network") {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Searching the network for computers…").foregroundStyle(.secondary)
                }
            }
        }
    }

    private func computerButton(_ row: ComputerRow) -> some View {
        Button { open(row) } label: {
            HStack(spacing: 12) {
                ComputerIcon(size: 40, isOnline: row.isOnline)
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.name).font(.headline).foregroundStyle(.primary)
                    Text(row.subtitle).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain) // keep the button tint from coloring the whole row
        .disabled(controller.state == .connecting)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("computer.\(row.name)")
    }

    @ViewBuilder
    private func contextMenu(for row: ComputerRow) -> some View {
        Button("Connect", systemImage: "play") { open(row) }
        if case .saved(let connection) = row.source {
            Button("Re-enter password…", systemImage: "key") { login = LoginRequest(saved: connection) }
            if #available(iOS 26, *) {
                if connection.helper != nil {
                    Button("Open App Mode windows", systemImage: "macwindow") {
                        if AppModeOpener.canOpenSeveralScenes {
                            openWindow(id: AppModeScene.id, value: SceneRole.launcher(computerID: connection.id))
                        } else {
                            phoneAppMode = connection
                        }
                    }
                }
                Button(connection.helper == nil ? "Set up App Mode…" : "Pair App Mode again…", systemImage: "qrcode.viewfinder") {
                    pairingFor = connection
                }
                if connection.helper != nil {
                    Button("Streaming settings…", systemImage: "slider.horizontal.3") { streamingFor = connection }
                }
            }
            Button("Delete", systemImage: "trash", role: .destructive) { delete(connection) }
        }
    }

    /// When there is nothing to choose yet: say what to do on the Mac side instead of leaving the screen empty.
    private var helpSection: some View {
        Section {
            VStack(spacing: 10) {
                Image(systemName: browser.denied ? "lock.shield" : "desktopcomputer")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)
                if browser.denied {
                    Text("Local Network access not granted").font(.headline)
                    Text("Allow Screon to search the network so it can find Macs automatically, or enter an address above.")
                        .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Searching the network for computers…").font(.headline)
                    }
                    Text("On the Mac, turn on System Settings › General › Sharing › Screen Sharing. The Mac and this device must be on the same Wi-Fi network.")
                        .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
    }

    // MARK: - Connecting

    private var connectingCard: some View {
        VStack(spacing: 14) {
            ProgressView().controlSize(.large)
            Text("Connecting to \(connectingName)…").font(.headline).multilineTextAlignment(.center)
            Button("Cancel") { controller.disconnect() }
                .buttonStyle(.bordered)
        }
        .padding(24)
        .frame(maxWidth: 300)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(radius: 20)
        .transition(.opacity)
    }

    private var failureAlertShown: Binding<Bool> {
        Binding(
            get: { login == nil && failureMessage != nil },
            set: { shown in
                if !shown { controller.dismissFailure() }
            }
        )
    }

    // MARK: - Actions

    private func open(_ row: ComputerRow) {
        addressError = nil
        switch row.source {
        case .saved(let connection):
            if let stored = model.password(for: connection) {
                connectingName = connection.name
                lastSaved = connection
                controller.connect(target: connection.target, username: connection.username, password: stored) {
                    model.markUsed(connection)
                }
            } else {
                login = LoginRequest(saved: connection)
            }
        case .discovered(let host):
            lastSaved = nil
            login = LoginRequest(target: host.target, name: host.name, username: "")
        }
    }

    private func connectToAddress() {
        switch ConnectionDraft(host: address).validated() {
        case .failure(.emptyHost):
            addressError = String(localized: "Enter a computer name or address.")
        case .failure(.invalidPort):
            addressError = String(localized: "The port must be a number from 1 to 65535.")
        case .success(let valid):
            addressError = nil
            addressFocused = false
            let target = SavedConnection.Target.host(valid.host, port: valid.port)
            let known = model.connection(for: target)
            lastSaved = nil
            login = LoginRequest(target: target, name: valid.host, username: valid.username ?? known?.username ?? "")
        }
    }

    /// Connect from the login dialog. Only saves AFTER a successful connection: a mistyped address or password leaves no junk in the list.
    private func connect(_ request: LoginRequest, username: String, password: String, remember: Bool) {
        connectingName = request.name
        lastSaved = nil
        let target = request.target
        let name = request.name
        controller.connect(target: target, username: username, password: password) {
            guard remember else { return }
            model.remember(target: target, username: username, password: password, name: name)
        }
    }

    private func delete(_ connection: SavedConnection) {
        do { try model.delete(connection) } catch { model.lastError = error.localizedDescription }
    }
}

/// A computer currently being asked for name and password in the dialog.
struct LoginRequest: Identifiable {
    let id = UUID()
    let target: SavedConnection.Target
    let name: String
    /// Prefilled account name (saved computer, or typed as `account@host`).
    let username: String

    init(target: SavedConnection.Target, name: String, username: String) {
        self.target = target
        self.name = name
        self.username = username
    }

    init(saved: SavedConnection) {
        self.init(target: saved.target, name: saved.name, username: saved.username)
    }
}

/// Computer icon: a blue rounded tile, with a green dot while Bonjour can see the computer.
struct ComputerIcon: View {
    var size: CGFloat = 40
    var isOnline = false

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
            .fill(LinearGradient(colors: [.blue, .indigo], startPoint: .top, endPoint: .bottom))
            .frame(width: size, height: size)
            .overlay { Image(systemName: "desktopcomputer").font(.system(size: size * 0.5)).foregroundStyle(.white) }
            .overlay(alignment: .bottomTrailing) {
                if isOnline {
                    Circle()
                        .fill(.green)
                        .frame(width: size * 0.3, height: size * 0.3)
                        .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 2))
                        .offset(x: 3, y: 3)
                        .accessibilityHidden(true)
                }
            }
            .accessibilityHidden(true)
    }
}

/// The "Enter name and password" dialog, like Screen Sharing's: results (connecting, wrong password…) appear right here,
/// and the fields stay as they are so you can fix them and retry. On success the computer picker disappears along with this dialog.
struct LoginSheet: View {
    let request: LoginRequest
    let controller: SessionController
    let onConnect: (_ username: String, _ password: String, _ remember: Bool) -> Void
    let onCancel: () -> Void

    @State private var username: String
    @State private var password = ""
    @State private var remember = true
    @FocusState private var focus: Field?

    private enum Field { case username, password }

    init(
        request: LoginRequest,
        controller: SessionController,
        onConnect: @escaping (String, String, Bool) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.request = request
        self.controller = controller
        self.onConnect = onConnect
        self.onCancel = onCancel
        _username = State(initialValue: request.username)
    }

    private var isConnecting: Bool { controller.state == .connecting }
    private var canConnect: Bool { !password.isEmpty && !isConnecting }

    private var failure: String? {
        if case .failed(let message) = controller.state { return message }
        return nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: 10) {
                        ComputerIcon(size: 64)
                        Text("Screen sharing with “\(request.name)”")
                            .font(.headline)
                            .multilineTextAlignment(.center)
                        Text("Enter the name and password of a macOS account on this computer.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                }

                Section {
                    TextField("Account name", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textContentType(.username)
                        .submitLabel(.next)
                        .focused($focus, equals: .username)
                        .onSubmit { focus = .password }
                        .accessibilityIdentifier("login-username")
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                        .submitLabel(.go)
                        .focused($focus, equals: .password)
                        .onSubmit(submit)
                        .accessibilityIdentifier("login-password")
                } footer: {
                    if let failure {
                        Text(failure).foregroundStyle(.red)
                    } else if username.isEmpty {
                        Text("The Mac needs a macOS account name. Leave it empty only if the computer uses a VNC password (weaker than an account login).")
                    }
                }
                .disabled(isConnecting)

                Section {
                    Toggle("Remember password in Keychain", isOn: $remember)
                } footer: {
                    Text("The password stays only in this device's Keychain and is not synced to iCloud.\n\n\(ConnectionSecurityNotice.loginFooter)")
                }
                .disabled(isConnecting)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isConnecting {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("Connecting…")
                        }
                    } else {
                        Button("Connect", action: submit)
                            .fontWeight(.semibold)
                            .disabled(!canConnect)
                            .accessibilityIdentifier("login-connect")
                    }
                }
            }
        }
        .interactiveDismissDisabled(isConnecting)
        .task { focus = username.isEmpty ? .username : .password }
    }

    private func submit() {
        guard canConnect else { return }
        onConnect(username.trimmingCharacters(in: .whitespaces), password, remember)
    }
}
