import LinkProtocol
import SwiftUI
import UIKit
import WindowKit

/// Which remote-window scene has the focus, and so whose Mac app the iPadOS 26 menu bar shows.
@available(iOS 26, *)
@MainActor
final class FocusedRemoteMenu {
    static let shared = FocusedRemoteMenu()

    private(set) weak var focused: RemoteWindowSceneModel?

    func focus(_ model: RemoteWindowSceneModel) {
        guard focused !== model else { return }
        focused = model
        model.focusGained()
        UIMainMenuSystem.shared.setNeedsRebuild()
    }

    func blur(_ model: RemoteWindowSceneModel) {
        guard focused === model else { return }
        focused = nil
        UIMainMenuSystem.shared.setNeedsRebuild()
    }

    /// The tree changed or the focus moved.
    func menusChanged() { UIMainMenuSystem.shared.setNeedsRebuild() }
}

/// The iPadOS 26 menu bar: a "Mac App" menu whose content is the menu tree of the app in the focused remote window.
///
/// The menu bar is built from one configuration for the whole app. The "Mac App" menu holds a deferred element that is evaluated each
/// time the menu opens, so it always reads the scene that has the focus then; the tree comes from the cache (and is fetched when the
/// scene gains focus), and a changed tree rebuilds the menu bar.
@available(iOS 26, *)
@MainActor
enum RemoteMenuBar {
    static let menuIdentifier = UIMenu.Identifier("com.ledinhcuong.screon.remote-app-menu")

    static func install() {
        let configuration = UIMainMenuSystem.Configuration()
        UIMainMenuSystem.shared.setBuildConfiguration(configuration) { builder in
            let deferred = UIDeferredMenuElement.uncached { completion in
                nonisolated(unsafe) let finish = completion
                Task { @MainActor in finish(await RemoteMenuBar.elements()) }
            }
            let menu = UIMenu(title: String(localized: "Mac App"), identifier: menuIdentifier, children: [deferred])
            builder.insertSibling(menu, afterMenu: .view)
        }
    }

    static func elements() async -> [UIMenuElement] {
        guard let model = FocusedRemoteMenu.shared.focused, let bundleID = model.focusedBundleID else {
            return [UIAction(title: String(localized: "No Mac app in focus"), attributes: .disabled) { _ in }]
        }
        let entries = await model.menuEntriesWaiting(bundleID: bundleID)
        guard !entries.isEmpty else {
            return [UIAction(title: String(localized: "No menu available"), attributes: .disabled) { _ in }]
        }
        let shortcutPaths = Set(RemoteMenuMapper.keyCommands(from: entries, closePolicy: AppModePreferences.closeShortcut).map(\.path))
        return makeElements(entries, bundleID: bundleID, shortcutPaths: shortcutPaths)
    }

    /// Entries as UIKit elements. Separators split a menu into inline groups.
    static func makeElements(_ entries: [RemoteMenuEntry], bundleID: String, shortcutPaths: Set<[UInt16]>) -> [UIMenuElement] {
        var groups: [[UIMenuElement]] = [[]]
        for entry in entries {
            if entry.isSeparator {
                if !(groups.last?.isEmpty ?? true) { groups.append([]) }
                continue
            }
            groups[groups.count - 1].append(element(for: entry, bundleID: bundleID, shortcutPaths: shortcutPaths))
        }
        groups = groups.filter { !$0.isEmpty }
        if groups.count <= 1 { return groups.first ?? [] }
        return groups.map { UIMenu(title: "", options: .displayInline, children: $0) }
    }

    private static func element(for entry: RemoteMenuEntry, bundleID: String, shortcutPaths: Set<[UInt16]>) -> UIMenuElement {
        let title = entry.title.isEmpty ? " " : entry.title
        if let children = entry.children {
            return UIMenu(title: title, children: makeElements(children, bundleID: bundleID, shortcutPaths: shortcutPaths))
        }
        let attributes: UIMenuElement.Attributes = entry.enabled ? [] : .disabled
        let state: UIMenuElement.State = entry.checked ? .on : .off
        if let shortcut = entry.shortcut, shortcutPaths.contains(entry.path) {
            return UIKeyCommand(
                title: title, image: nil, action: #selector(UIResponder.screonRemoteMenuItem(_:)), input: shortcut.input,
                modifierFlags: shortcut.modifiers.uiKit, propertyList: Self.propertyList(bundleID: bundleID, path: entry.path),
                alternates: [], discoverabilityTitle: nil, attributes: attributes, state: state)
        }
        let path = entry.path
        return UIAction(title: title, attributes: attributes, state: state) { _ in
            FocusedRemoteMenu.shared.focused?.pressMenu(bundleID: bundleID, path: path)
        }
    }

    static func propertyList(bundleID: String, path: [UInt16]) -> [String: Any] {
        ["b": bundleID, "p": path.map { Int($0) }]
    }
}

extension LinkModifiers {
    var uiKit: UIKeyModifierFlags {
        var flags: UIKeyModifierFlags = []
        if contains(.shift) { flags.insert(.shift) }
        if contains(.control) { flags.insert(.control) }
        if contains(.option) { flags.insert(.alternate) }
        if contains(.command) { flags.insert(.command) }
        return flags
    }
}

/// Key commands and menu items reach the focused remote-window scene through the responder chain: any responder implements these, the
/// first one in the chain answers.
extension UIResponder {
    /// A Mac menu item chosen from the menu bar or by its key equivalent. The command's property list names app and path.
    @objc @MainActor func screonRemoteMenuItem(_ sender: Any?) {
        guard #available(iOS 26, *), let command = sender as? UICommand, let list = command.propertyList as? [String: Any],
              let bundleID = list["b"] as? String, bundleID.utf8.count <= 512, let numbers = list["p"] as? [Int],
              let path = RemoteMenuMapper.decodePath(numbers) else { return }
        FocusedRemoteMenu.shared.focused?.pressMenu(bundleID: bundleID, path: path)
    }

    /// ⌘W while it closes the iPad window.
    @objc @MainActor func screonCloseRemoteWindow(_ sender: Any?) {
        guard #available(iOS 26, *) else { return }
        FocusedRemoteMenu.shared.focused?.requestCloseScene()
    }
}

/// The menus of a Mac app as a SwiftUI menu, for the toolbar "Menus" button (the fallback where the menu bar is not shown).
struct RemoteMenuItems: View {
    let entries: [RemoteMenuEntry]
    let press: ([UInt16]) -> Void

    var body: some View {
        ForEach(entries) { entry in
            if entry.isSeparator {
                Divider()
            } else if let children = entry.children {
                Menu(entry.title) { RemoteMenuItems(entries: children, press: press) }
                    .disabled(!entry.enabled)
            } else {
                Button {
                    press(entry.path)
                } label: {
                    if entry.checked {
                        Label(entry.title, systemImage: "checkmark")
                    } else {
                        Text(entry.title)
                    }
                }
                .disabled(!entry.enabled)
                .accessibilityIdentifier("menu-item-" + entry.path.map(String.init).joined(separator: "."))
            }
        }
    }
}

/// Sets up the menu bar once the app has launched.
final class ScreonAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        if #available(iOS 26, *) { MainActor.assumeIsolated { RemoteMenuBar.install() } }
        return true
    }
}
