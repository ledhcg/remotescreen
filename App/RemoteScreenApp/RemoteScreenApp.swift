import ConnectionKit
import Localization
import SwiftUI

@main
struct RemoteScreenApp: App {
    /// One computer list for EVERY window of the app. If each window kept its own copy, the window that saves last would overwrite
    /// the file with its stale list, losing the computer the other window just saved (leaving that computer's password
    /// orphaned in the Keychain).
    @State private var model = ConnectionsModel(
        store: ConnectionStore(fileURL: ConnectionStore.defaultURL()), secrets: KeychainSecretStore()
    )

    init() {
        // English-only build: messages from the packages follow the same language as the app's own strings.
        Localization.forcedLanguage = "en"
    }

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
        }
    }
}
