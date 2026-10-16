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
            AppModeWindowListView(computerID: computerID)
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

/// A plain list of a Mac's windows, until the launcher scene exists: tap a window to open it in its own iPad window.
@available(iOS 26, *)
struct AppModeWindowListView: View {
    let computerID: UUID
    @Environment(LinkSessionRegistry.self) private var registry
    @Environment(\.openWindow) private var openWindow
    @State private var connection: AppModeConnection?

    var body: some View {
        NavigationStack {
            Group {
                if let connection {
                    list(connection)
                } else {
                    ProgressView()
                }
            }
            .navigationTitle(connection?.macName ?? String(localized: "App Mode"))
        }
        .onAppear { if connection == nil { connection = registry.acquireConnection(computerID: computerID) } }
        .onDisappear {
            guard connection != nil else { return }
            connection = nil
            registry.release(computerID: computerID)
        }
    }

    @ViewBuilder
    private func list(_ connection: AppModeConnection) -> some View {
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
        } else {
            List(connection.workspace.windowsForLauncher, id: \.id) { window in
                Button {
                    openWindow(id: AppModeScene.id, value: SceneRole.remoteWindow(computerID: computerID, windowRef: String(window.id.rawValue)))
                } label: {
                    VStack(alignment: .leading) {
                        Text(connection.workspace.app(bundleID: window.bundleID)?.name ?? window.bundleID).font(.headline)
                        if !window.title.isEmpty { Text(window.title).font(.subheadline).foregroundStyle(.secondary) }
                    }
                }
            }
            .overlay {
                if connection.workspace.windowsForLauncher.isEmpty {
                    ContentUnavailableView("No windows", systemImage: "macwindow", description: Text("Open an app on the Mac to see its windows here."))
                }
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
