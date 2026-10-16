import LinkProtocol
import SessionKit
import SwiftUI
import UIKit
import WindowKit

/// Knows which `UIWindowScene` shows which Mac window, so that "open this window" can bring the existing scene forward and a scene
/// can be destroyed from the inside (the user chose Close on a window that is gone).
///
/// SwiftUI opens scenes with `openWindow(value:)` and already focuses a scene whose value is equal; this registry covers the case
/// where the same Mac window is asked for with a different reference (its title changed since).
@available(iOS 26, *)
@MainActor
final class SceneRegistry {
    static let shared = SceneRegistry()

    private struct Entry { weak var scene: UIWindowScene? }
    private var entries: [SceneID: Entry] = [:]

    func register(_ id: SceneID, scene: UIWindowScene) { entries[id] = Entry(scene: scene) }

    func unregister(_ id: SceneID) { entries[id] = nil }

    func scene(for id: SceneID) -> UIWindowScene? { entries[id]?.scene }

    /// Brings the scene to the front. False when it is unknown (or already gone).
    @discardableResult
    func activate(_ id: SceneID) -> Bool {
        guard let scene = scene(for: id) else { return false }
        UIApplication.shared.activateSceneSession(for: UISceneSessionActivationRequest(session: scene.session)) { error in
            Self.log(error)
        }
        return true
    }

    /// Destroys the scene (its window closes). False when the scene is unknown, so the caller can use `dismissWindow`.
    @discardableResult
    func destroy(_ id: SceneID) -> Bool {
        guard let scene = scene(for: id) else { return false }
        UIApplication.shared.requestSceneSessionDestruction(scene.session, options: nil) { error in Self.log(error) }
        return true
    }

    nonisolated private static func log(_ error: Error) {
        NSLog("Screon scene request failed: %{public}@", String(describing: type(of: error)))
    }
}

/// Reports the `UIWindowScene` a SwiftUI view lives in and the size of the area it fills, in points.
@available(iOS 26, *)
struct SceneBridge: UIViewRepresentable {
    var onScene: (UIWindowScene?) -> Void
    var onSize: (CGSize) -> Void
    var onController: (UIViewController?) -> Void

    final class BridgeView: UIView {
        var onScene: ((UIWindowScene?) -> Void)?
        var onSize: ((CGSize) -> Void)?
        var onController: ((UIViewController?) -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            onScene?(window?.windowScene)
            var responder: UIResponder? = self
            while let next = responder?.next {
                if let controller = next as? UIViewController { onController?(controller); break }
                responder = next
            }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            onSize?(bounds.size)
        }
    }

    func makeUIView(context: Context) -> BridgeView {
        let view = BridgeView()
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        view.onScene = onScene
        view.onSize = onSize
        view.onController = onController
        return view
    }

    func updateUIView(_ view: BridgeView, context: Context) {
        view.onScene = onScene
        view.onSize = onSize
        view.onController = onController
    }
}

/// Opens Mac windows as scenes (or, where there can only be one scene, in the scene that is there).
@available(iOS 26, *)
@MainActor
struct AppModeOpener {
    let computerID: UUID
    let openWindow: OpenWindowAction
    /// Set where all windows share one scene (iPhone): shows the window there.
    var showHere: ((WindowID) -> Void)?

    /// iPad can have a scene per Mac window; iPhone has the one scene.
    static var canOpenSeveralScenes: Bool {
        UIApplication.shared.supportsMultipleScenes && UIDevice.current.userInterfaceIdiom == .pad
    }

    var canOpenSeveralScenes: Bool { showHere == nil && Self.canOpenSeveralScenes }

    /// Shows a window: the scene that has it comes forward, otherwise a scene is opened (or the single scene switches to it).
    func show(_ window: WindowID, in connection: AppModeConnection) {
        if let showHere {
            showHere(window)
            return
        }
        if let scene = connection.bindings.scene(for: window), SceneRegistry.shared.activate(scene) { return }
        guard let ref = WindowRef(window: window, in: connection.workspace) else { return }
        openWindow(id: AppModeScene.id, value: SceneRole.remoteWindow(computerID: computerID, windowRef: ref.encoded))
        // Mac side: raise it too, so what is on top matches what the iPad shows.
        connection.command(.raise, on: window)
    }

    /// Does what tapping an app should do.
    func open(app bundleID: String, in connection: AppModeConnection) {
        let style = AppModePreferences.openStyle
        let plan = connection.openApp(bundleID: bundleID, style: style, canOpenSeveralScenes: canOpenSeveralScenes)
        for window in plan.windowsToFocus + plan.windowsToOpen { show(window, in: connection) }
    }

    /// Opens scenes for new Mac windows the connection wants shown.
    func openNewWindows(of connection: AppModeConnection) {
        for window in connection.takeWindowsToOpen() { show(window, in: connection) }
    }
}

/// iPhone: the one scene shows one window at a time; this says which (or none, then the launcher).
@available(iOS 26, *)
@MainActor
@Observable
final class PhoneNavigation {
    var windowRef: String?
    var showsSwitcher = false
    /// Set to show the Mac's whole screen (Screen Sharing) instead.
    var desktopComputerID: UUID?

    func show(_ window: WindowID, in connection: AppModeConnection, computerID: UUID) {
        guard let ref = WindowRef(window: window, in: connection.workspace) else { return }
        windowRef = ref.encoded
        showsSwitcher = false
    }

    func showLauncher() {
        windowRef = nil
        showsSwitcher = false
    }
}
