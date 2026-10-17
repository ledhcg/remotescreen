import ConnectionKit
import Localization
import SwiftUI
import UIKit

@main
struct ScreonApp: App {
    @UIApplicationDelegateAdaptor(ScreonAppDelegate.self) private var appDelegate

    /// One computer list for EVERY window of the app. If each window kept its own copy, the window that saves last would overwrite
    /// the file with its stale list, losing the computer the other window just saved (leaving that computer's password
    /// orphaned in the Keychain).
    @State private var model: ConnectionsModel

    /// Link sessions of App Mode, shared by every App Mode window.
    @State private var linkSessions: LinkSessionRegistry

    init() {
        // English-only build: messages from the packages follow the same language as the app's own strings.
        Localization.forcedLanguage = "en"
        // Start watching the network now, so the first connection is checked against a real snapshot.
        NetworkMonitor.shared.start()
        #if DEBUG
        let model = DebugComputers.model() ?? ConnectionsModel(
            store: ConnectionStore(fileURL: ConnectionStore.defaultURL()), secrets: KeychainSecretStore()
        )
        #else
        let model = ConnectionsModel(
            store: ConnectionStore(fileURL: ConnectionStore.defaultURL()), secrets: KeychainSecretStore()
        )
        #endif
        _model = State(initialValue: model)
        _linkSessions = State(initialValue: LinkSessionRegistry(makeSession: { computerID in
            if #available(iOS 26, *) {
                return AppModeConnection(computerID: computerID) { model.saved.first { $0.id == computerID } }
            }
            return UnavailableSession()
        }))
    }

    var body: some Scene {
        // Desktop role: today's whole-screen view, the default scene.
        WindowGroup {
            RootView(model: model)
                .environment(model)
                .environment(linkSessions)
        }
        // Launcher and remote-window roles (App Mode).
        appModeScenes
    }

    @SceneBuilder private var appModeScenes: some Scene {
        if #available(iOS 26, *) {
            AppModeScenes(model: model, registry: linkSessions)
        }
    }
}
