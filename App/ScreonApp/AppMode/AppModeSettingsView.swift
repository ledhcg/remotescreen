import ConnectionKit
import SwiftUI

/// The streaming choices for one computer in App Mode: how much quality and how many frames per second the Mac may use, 10-bit video,
/// and sound. Saved with the computer; a change applies to the windows opened or resized afterwards (sound and 10-bit video, at the
/// next connection).
struct AppModeSettingsView: View {
    let computer: SavedConnection
    let model: ConnectionsModel
    @Environment(\.dismiss) private var dismiss
    @State private var settings: AppModeSettings
    @State private var limitsFrameRate: Bool
    @State private var saveError: String?

    init(computer: SavedConnection, model: ConnectionsModel) {
        self.computer = computer
        self.model = model
        let current = computer.appModeSettings
        _settings = State(initialValue: current)
        _limitsFrameRate = State(initialValue: current.maxFramesPerSecond != nil)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Quality", selection: $settings.qualityCap) {
                        Text("Low (saves bandwidth)").tag(AppModeSettings.QualityCap.low)
                        Text("Balanced").tag(AppModeSettings.QualityCap.balanced)
                        Text("High").tag(AppModeSettings.QualityCap.high)
                    }
                    .accessibilityIdentifier("quality-picker")
                    Toggle("Limit the frame rate", isOn: $limitsFrameRate)
                    if limitsFrameRate {
                        Stepper(
                            "Up to \(settings.maxFramesPerSecond ?? 60) frames per second",
                            value: Binding(
                                get: { settings.maxFramesPerSecond ?? 60 },
                                set: { settings.maxFramesPerSecond = $0 }
                            ),
                            in: AppModeSettings.frameRateRange, step: 15
                        )
                    }
                } header: {
                    Text("Picture")
                } footer: {
                    Text("The Mac sends less than this when the network is slow. A lower limit saves bandwidth and battery.")
                }
                Section {
                    Toggle("10-bit video (Main 10)", isOn: $settings.allowMain10)
                } footer: {
                    Text("Smoother gradients, but it needs more bandwidth. Takes effect the next time you connect.")
                }
                Section {
                    Toggle("Play sound from the Mac", isOn: $settings.playAudio)
                } footer: {
                    Text("Plays the sound of the apps whose windows are open. Takes effect the next time you connect.")
                }
                if let saveError {
                    Section { Text("Couldn't save: \(saveError)").foregroundStyle(.red) }
                }
            }
            .navigationTitle("Streaming")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save", action: save) }
            }
        }
    }

    private func save() {
        var chosen = settings
        if !limitsFrameRate { chosen.maxFramesPerSecond = nil }
        var updated = computer
        updated.appMode = chosen == .standard ? nil : chosen
        do {
            try model.save(updated, password: nil)
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }
    }
}
