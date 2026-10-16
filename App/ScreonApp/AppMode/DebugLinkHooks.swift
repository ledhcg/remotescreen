#if DEBUG
import ConnectionKit
import Foundation
import SessionKit
import WindowKit

/// Test hooks for App Mode UI tests, DEBUG builds only (like `RFB_HOST` for the Screen Sharing mode):
///
/// - `LINK_HOST`, `LINK_PORT`: the helper to use (a mock on 127.0.0.1). Without `LINK_PAIRING` the iPad must already be paired with it.
/// - `LINK_PAIRING`: the text of the pairing QR code. The app pairs with it, then connects.
///
/// - `LINK_OPEN`: `launcher` opens the launcher scene; `window` (the default) opens the first managed window in its own scene.
///
/// Only the first scene of a launch runs this.
@available(iOS 26, *)
@MainActor
enum DebugLinkHooks {
    private static var claimed = false

    static func claim() -> Bool {
        defer { claimed = true }
        return !claimed && ProcessInfo.processInfo.environment["LINK_HOST"] != nil
    }

    static func run(model: ConnectionsModel, registry: LinkSessionRegistry, open: @MainActor @escaping (SceneRole) -> Void) async {
        let environment = ProcessInfo.processInfo.environment
        guard let host = environment["LINK_HOST"], let port = environment["LINK_PORT"].flatMap({ UInt16($0) }) else { return }

        let name = "Link test Mac"
        let target = SavedConnection.Target.host(host, port: port)
        var computer = model.saved.first { $0.name == name } ?? SavedConnection(name: name, target: target, username: "")
        if let text = environment["LINK_PAIRING"] {
            do {
                let outcome = try await LinkPairing.pair(qrText: text, computerID: computer.id, addressOverride: (host, port))
                computer.helper = outcome.helperEndpoint
            } catch {
                NSLog("DebugLinkHooks: pairing failed: %@", String(describing: error))
                model.lastError = LinkPairing.message(for: error)
                return
            }
        } else {
            computer.helper = HelperEndpoint(identityHash: "", lastKnownHost: host, lastKnownPort: port, pairedAt: Date())
        }
        do { try model.save(computer, password: nil) } catch {
            model.lastError = error.localizedDescription
            return
        }

        // Hold a reference for the whole run so the session survives while the window scene comes up.
        guard let connection = registry.acquireConnection(computerID: computer.id) else { return }
        if environment["LINK_OPEN"] == "launcher" {
            open(.launcher(computerID: computer.id))
            return
        }
        for _ in 0..<200 where !connection.workspace.hasSnapshot {
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard let window = connection.workspace.orderedWindows.first(where: { $0.isManaged }) else { return }
        open(.remoteWindow(computerID: computer.id, windowRef: WindowRef(window: window.id, in: connection.workspace)?.encoded ?? String(window.id.rawValue)))
    }
}
#endif
