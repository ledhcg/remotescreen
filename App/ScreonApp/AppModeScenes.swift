import SessionKit
import SwiftUI

/// Scene id used with `openWindow(id:value:)` to open App Mode windows (launcher or remote window) for a `SceneRole`.
enum AppModeScene {
    static let id = "app-mode"
}

/// Placeholder content of the App Mode scenes until the launcher and remote windows exist.
@available(iOS 26, *)
struct AppModeRoleView: View {
    let role: SceneRole?

    var body: some View {
        ContentUnavailableView {
            Label("App Mode", systemImage: "macwindow")
        } description: {
            Text("App Mode is not available yet.")
        }
    }
}

/// The App Mode scenes. App Mode needs iPadOS 26 (free-form windows); the app itself still supports iOS 18.
@available(iOS 26, *)
struct AppModeScenes: Scene {
    var body: some Scene {
        WindowGroup(id: AppModeScene.id, for: SceneRole.self) { $role in
            AppModeRoleView(role: role)
        }
    }
}
