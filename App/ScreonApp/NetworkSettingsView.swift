import ConnectionKit
import SessionKit
import SwiftUI

/// Network settings of the app: whether to use Tailscale, with what the device's network looks like right now.
struct NetworkSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(NetworkPreferences.useTailscaleKey) private var useTailscale = true
    private let monitor = NetworkMonitor.shared
    private let tailnet = TailnetDirectory.shared
    @State private var token = ""
    @State private var tokenError: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Status", value: linkDescription)
                        .accessibilityIdentifier("network-status")
                } header: {
                    Text("This device")
                }
                Section {
                    Toggle("Use Tailscale", isOn: $useTailscale)
                        .accessibilityIdentifier("use-tailscale")
                    // Plain text rows: a `Label` inside `LabeledContent` made the row (and its whole card) grow far taller than its content.
                    LabeledContent(
                        "Tailscale on this device",
                        value: monitor.snapshot.usesTailscale ? String(localized: "Connected") : String(localized: "Not connected")
                    )
                    .accessibilityIdentifier("tailscale-status")
                    if let address = monitor.snapshot.tailscaleAddress {
                        LabeledContent("Tailscale address", value: address)
                            .accessibilityIdentifier("tailscale-address")
                    }
                } header: {
                    Text("Tailscale")
                } footer: {
                    Text("Screon detects Tailscale on this device by itself. When it is connected, Macs can be reached by their Tailscale address away from home, and on mobile data that address is tried first. Turn this off to use only the local network. Takes effect the next time you connect.")
                }
                Section {
                    SecureField(tailnet.hasToken ? "Token saved" : "Tailscale API token", text: $token)
                        .textContentType(.password)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .onSubmit(saveToken)
                        .accessibilityIdentifier("tailscale-token")
                    if !token.isEmpty {
                        Button("Save token", action: saveToken)
                    }
                    if tailnet.hasToken {
                        LabeledContent("Devices", value: tailnetStatus)
                            .accessibilityIdentifier("tailnet-status")
                        Button("Refresh now") { tailnet.refresh(force: true) }
                        Button("Remove token", role: .destructive) { removeToken() }
                    }
                    if let tokenError {
                        Text(tokenError).foregroundStyle(.red)
                    }
                } header: {
                    Text("Macs on your tailnet")
                } footer: {
                    Text("To list the Macs of your tailnet that are not saved yet, Screon reads your device list from Tailscale: create an access token in the Tailscale admin console (Settings › Keys) and paste it here. It stays only in this device's Keychain and is sent only to api.tailscale.com. A token can manage your tailnet and expires within 90 days: remove it here, or revoke it in the admin console, when you no longer need it. Without a token, saved computers are still checked over Tailscale.")
                }
            }
            .navigationTitle("Network")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }

    private var tailnetStatus: String {
        switch tailnet.status {
        case .notConfigured, .idle:
            monitor.snapshot.usesTailscale ? String(localized: "Waiting") : String(localized: "Tailscale is not connected")
        case .loading: String(localized: "Reading…")
        case .loaded: String(localized: "\(tailnet.devices.count) devices")
        case .failed(.unauthorized): String(localized: "Token not accepted")
        case .failed(.unexpectedResponse): String(localized: "Unexpected answer")
        case .failed(.network): String(localized: "Couldn't reach Tailscale")
        }
    }

    private func saveToken() {
        do {
            try tailnet.setToken(token)
            token = ""
            tokenError = nil
        } catch {
            tokenError = String(localized: "Couldn't save: \(error.localizedDescription)")
        }
    }

    private func removeToken() {
        do {
            try tailnet.setToken("")
            tokenError = nil
        } catch {
            tokenError = String(localized: "Couldn't remove: \(error.localizedDescription)")
        }
    }

    private var linkDescription: String {
        let snapshot = monitor.snapshot
        guard snapshot.isOnline else { return String(localized: "Offline") }
        switch snapshot.link {
        case .wifi: return String(localized: "Wi-Fi")
        case .cellular: return String(localized: "Mobile data")
        case .wired: return String(localized: "Wired network")
        case .other, .none: return String(localized: "Online")
        }
    }
}
