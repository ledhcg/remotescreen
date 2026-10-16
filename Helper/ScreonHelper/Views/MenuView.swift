import AppKit
import HelperCore
import LinkTransport
import SwiftUI

struct MenuView: View {
    @Bindable var model: HelperModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            issues
            sessions
            pairedDevices
            actions
            Divider()
            settings
            Divider()
            updateRow
            footer
        }
        .padding(14)
        .frame(width: 340)
    }

    // MARK: Status

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: model.menuBarSymbol)
                .font(.title2)
                .foregroundStyle(model.status.issues.isEmpty && model.startError == nil ? Color.accentColor : .orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Screon Helper").font(.headline)
                statusLine.font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    @ViewBuilder private var statusLine: some View {
        if model.startError != nil {
            Text("Not running")
        } else {
            switch model.status.phase {
            case .stopped: Text("Stopped")
            case .starting: Text("Starting…")
            case .failed: Text("Not running")
            case .running:
                if let port = model.status.listeningPort {
                    Text("Listening on port \(Int(port))")
                } else {
                    Text("Listening")
                }
            }
        }
    }

    @ViewBuilder private var issues: some View {
        let list = model.status.issues
        if model.startError != nil || !list.isEmpty || !model.permissions.allGranted {
            VStack(alignment: .leading, spacing: 6) {
                if model.startError != nil {
                    Label("Screon Helper could not start listening for iPads.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Button("Try Again") { Task { await model.restartService() } }
                }
                ForEach(Array(list.enumerated()), id: \.offset) { _, issue in
                    if case .failed = issue { EmptyView() } else {
                        Label(issue.message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                }
                if !model.permissions.allGranted {
                    Button("Set Up Permissions…") { model.showOnboarding() }
                }
            }
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
        }
        if model.restartPending {
            Label("Some changes apply after the iPad disconnects.", systemImage: "clock")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Sessions

    @ViewBuilder private var sessions: some View {
        if !model.status.sessions.isEmpty {
            section("Connected iPads") {
                ForEach(model.status.sessions) { session in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(session.deviceName).lineLimit(1)
                            HStack(spacing: 4) {
                                Text("since")
                                Text(session.connectedAt, style: .time)
                                Text("·")
                                Text("\(session.subscribedWindows) windows")
                            }
                            .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Disconnect") { model.disconnect(sessionID: session.id) }
                            .controlSize(.small)
                    }
                }
            }
        }
    }

    // MARK: Paired devices

    @ViewBuilder private var pairedDevices: some View {
        section("Paired iPads") {
            if model.pairedDevices.isEmpty {
                Text("No iPad is paired yet.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(model.pairedDevices, id: \.spkiHash) { device in
                PairedDeviceRow(model: model, device: device)
            }
        }
    }

    // MARK: Actions

    private var actions: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button("Pair New iPad…") { model.beginQRPairing() }
                    .disabled(!model.status.isRunning)
                Button("Pair Without Camera…") { model.beginSASPairing() }
                    .disabled(!model.status.isRunning)
            }
            HStack {
                Button("Disconnect All") { model.disconnectAll() }
                    .disabled(model.status.sessions.isEmpty)
                Button("Restore Windows") { model.restoreWindows() }
                    .disabled(!model.status.isRunning)
            }
        }
        .controlSize(.small)
    }

    // MARK: Settings

    private var settings: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Ask before each session", isOn: $model.askBeforeEachSession)
            Toggle("Use a virtual display for windows", isOn: $model.useVirtualStage)
            Toggle("Stream app audio", isOn: $model.audioEnabled)
            Toggle("Open at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
            if model.loginItemStatus == .requiresApproval {
                HStack {
                    Text("Approve Screon Helper in Login Items.").font(.caption).foregroundStyle(.secondary)
                    Button("Open Settings") { model.openLoginItemsSettings() }.controlSize(.small)
                }
            } else if model.loginItemError {
                Text("Could not change the login item.").font(.caption).foregroundStyle(.orange)
            }
            Toggle("Check for updates automatically", isOn: $model.checkUpdatesAutomatically)
        }
        .toggleStyle(.checkbox)
        .font(.callout)
    }

    // MARK: Updates

    @ViewBuilder private var updateRow: some View {
        HStack {
            switch model.update {
            case .idle: EmptyView()
            case .checking: Text("Checking for updates…").foregroundStyle(.secondary)
            case .upToDate: Text("Screon Helper is up to date.").foregroundStyle(.secondary)
            case .available(let version, let url):
                Label("Update available: \(version)", systemImage: "arrow.down.circle.fill").foregroundStyle(Color.accentColor)
                Link("View Release", destination: url)
            case .needsNewerMacOS(let version):
                Text("Version \(version) needs a newer macOS.").foregroundStyle(.secondary)
            case .notConfigured: Text("Update checks are not set up in this build.").foregroundStyle(.secondary)
            case .failed: Text("Could not check for updates.").foregroundStyle(.orange)
            }
            Spacer()
            Button("Check Now") { Task { await model.checkForUpdates() } }
                .controlSize(.small)
                .disabled(model.update == .checking)
        }
        .font(.caption)
    }

    private var footer: some View {
        HStack {
            Text("Version \(model.versionString)").font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("Set Up…") { model.showOnboarding() }.controlSize(.small)
            Button("About") {
                NSApp.activate()
                NSApp.orderFrontStandardAboutPanel(nil)
            }.controlSize(.small)
            Button("Quit") { NSApp.terminate(nil) }
                .controlSize(.small)
                .keyboardShortcut("q")
        }
    }

    private func section<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.weight(.semibold))
            content()
        }
    }
}

private struct PairedDeviceRow: View {
    let model: HelperModel
    let device: PairedDevice
    @State private var editing = false
    @State private var draft = ""
    @State private var confirmingRevoke = false

    var body: some View {
        HStack {
            if editing {
                TextField("Name", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(commit)
                Button("Save", action: commit).controlSize(.small)
                Button("Cancel") { editing = false }.controlSize(.small)
            } else if confirmingRevoke {
                Text("Revoke “\(device.name)”?").lineLimit(1)
                Spacer()
                Button("Revoke", role: .destructive) {
                    confirmingRevoke = false
                    model.revoke(device)
                }.controlSize(.small)
                Button("Cancel") { confirmingRevoke = false }.controlSize(.small)
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    Text(device.name).lineLimit(1)
                    Text("Paired \(device.pairedAt, style: .date)").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    draft = device.name
                    editing = true
                } label: {
                    Image(systemName: "pencil")
                }
                .help("Rename")
                .accessibilityLabel(Text("Rename"))
                .controlSize(.small)
                Button("Revoke…") { confirmingRevoke = true }.controlSize(.small)
            }
        }
    }

    private func commit() {
        model.rename(device, to: draft)
        editing = false
    }
}
