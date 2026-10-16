import SessionKit
import SwiftUI

/// Network settings of the app: whether to use Tailscale, with what the device's network looks like right now.
struct NetworkSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(NetworkPreferences.useTailscaleKey) private var useTailscale = true
    private let monitor = NetworkMonitor.shared

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
                    LabeledContent("Tailscale on this device") {
                        if let address = monitor.snapshot.tailscaleAddress {
                            Label { Text("Connected (\(address))") } icon: { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                        } else {
                            Label { Text("Not connected") } icon: { Image(systemName: "circle.dashed").foregroundStyle(.secondary) }
                        }
                    }
                    .accessibilityIdentifier("tailscale-status")
                } header: {
                    Text("Tailscale")
                } footer: {
                    Text("Screon detects Tailscale on this device by itself. When it is connected, Macs can be reached by their Tailscale address away from home, and on mobile data that address is tried first. Turn this off to use only the local network. Takes effect the next time you connect.")
                }
            }
            .navigationTitle("Network")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
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
