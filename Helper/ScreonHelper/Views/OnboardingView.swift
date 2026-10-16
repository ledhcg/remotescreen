import SwiftUI

/// Live checklist of what the helper needs from macOS. The model re-checks every two seconds, so a row turns green by itself
/// when the person flips the switch in System Settings.
struct OnboardingView: View {
    let model: HelperModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Set Up Screon Helper").font(.title2.bold())
                Text("Screon Helper streams your Mac's windows to your iPad. macOS needs your permission for each part.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            row(
                granted: model.permissions.accessibility, title: "Accessibility",
                detail: "Lets the helper find windows and move the pointer and keys you send from the iPad.",
                grant: { model.request(.accessibility) }, pane: .accessibility)
            row(
                granted: model.permissions.postEvents, title: "Control input",
                detail: "Lets the helper post mouse and keyboard events. It is granted together with Accessibility on most Macs.",
                grant: { model.request(.postEvents) }, pane: .accessibility)
            row(
                granted: model.permissions.screenRecording, title: "Screen Recording",
                detail: "Lets the helper capture window contents. Newer versions of macOS may list this as Remote Desktop instead; macOS gives apps no way to check that one, so if windows stay black after you allow it, check both lists.",
                grant: { model.request(.screenRecording) }, pane: .screenRecording)
            networkRow

            Text("Some permissions only take effect after the helper restarts.")
                .font(.callout).foregroundStyle(.secondary)

            HStack {
                Button("Restart Helper") { model.relaunch() }
                Spacer()
                Button("Done") { model.finishOnboarding() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520)
    }

    private func row(
        granted: Bool, title: LocalizedStringKey, detail: LocalizedStringKey, grant: @escaping () -> Void,
        pane: HelperModel.SettingsPane
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle.dashed")
                .font(.title3)
                .foregroundStyle(granted ? Color.green : Color.orange)
                .accessibilityLabel(Text(LocalizedStringKey(granted ? "Allowed" : "Not allowed yet")))
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if !granted {
                    HStack {
                        Button("Allow…", action: grant)
                        Button("Open System Settings") { model.openSettings(pane) }
                    }
                    .controlSize(.small)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var networkRow: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: model.localNetworkNote == .listening ? "dot.radiowaves.left.and.right" : "questionmark.circle")
                .font(.title3)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("Local Network").font(.headline)
                Text(LocalizedStringKey(model.localNetworkNote == .listening
                     ? "The helper is listening. macOS has no way to check this permission: if your iPad cannot find this Mac, make sure Screon Helper is allowed here."
                     : "macOS asks for this when the helper starts listening. It has no way to check this permission."))
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Open System Settings") { model.openSettings(.localNetwork) }.controlSize(.small)
            }
            Spacer(minLength: 0)
        }
    }
}
