import ConnectionKit
import SessionKit
import SwiftUI
import WindowKit

/// Scene id used with `openWindow(id:value:)` to open App Mode windows (launcher or remote window) for a `SceneRole`.
enum AppModeScene {
    static let id = "app-mode"
}

/// The content of an App Mode scene, chosen by its role.
@available(iOS 26, *)
struct AppModeRoleView: View {
    let role: SceneRole?
    @Environment(ConnectionsModel.self) private var computers

    var body: some View {
        switch role {
        case .remoteWindow(let computerID, let windowRef)?:
            RemoteWindowSceneView(role: .remoteWindow(computerID: computerID, windowRef: windowRef), computerID: computerID, windowRef: windowRef)
        case .launcher(let computerID)?:
            LauncherView(computerID: computerID)
        case .computerDesktop(let computerID)?:
            RootView(model: computers, autoConnect: computers.saved.first { $0.id == computerID })
        case .desktop?:
            RootView(model: computers)
        case nil:
            ContentUnavailableView {
                Label("App Mode", systemImage: "macwindow")
            } description: {
                Text("Choose a window from the list of your computers.")
            }
        }
    }
}

/// The App Mode scenes. App Mode needs iPadOS 26 (free-form windows); the app itself still supports iOS 18.
@available(iOS 26, *)
struct AppModeScenes: Scene {
    let model: ConnectionsModel
    let registry: LinkSessionRegistry

    var body: some Scene {
        WindowGroup(id: AppModeScene.id, for: SceneRole.self) { $role in
            AppModeRoleView(role: role)
                .environment(model)
                .environment(registry)
        }
    }
}
