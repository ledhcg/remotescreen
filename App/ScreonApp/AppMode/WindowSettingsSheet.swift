import SwiftUI
import WindowKit

/// The options of a remote window as a bottom sheet (the "…" button of an App Mode window): icon and title on the left, the current value on
/// the right with a menu of the others, the Mac window's actions, and a red button at the foot that closes this window (or goes back to the apps).
@available(iOS 26, *)
struct WindowSettingsSheet: View {
    let model: RemoteWindowSceneModel
    let isPhone: Bool
    let openDesktop: () -> Void
    let closeScene: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let actions = WindowActionAvailability(window: model.boundState)
        SettingsSheet(
            title: "Options",
            destructiveTitle: isPhone ? "Back to apps" : "Close this window",
            destructiveImage: isPhone ? "rectangle.portrait.and.arrow.right" : "xmark.circle",
            destructiveIdentifier: "action-close-scene",
            destructiveAction: { dismiss(); closeScene() }
        ) {
            SettingsGroup(title: "View") {
                SettingsMenuRow(
                    systemImage: "arrow.down.right.and.arrow.up.left", title: "Fit",
                    selection: Bindable(model).fitMode,
                    options: [
                        SettingsOption(value: WindowFitMode.fit, title: "Fit"),
                        SettingsOption(value: WindowFitMode.fill, title: "Fill"),
                        SettingsOption(value: WindowFitMode.actual, title: "Actual size"),
                    ])
                SettingsToggleRow(systemImage: "keyboard", title: "Keyboard", isOn: Bindable(model).isKeyboardVisible)
                SettingsActionRow(systemImage: "arrow.up.left.and.down.right.magnifyingglass", title: "Reset zoom") {
                    model.view?.resetZoom()
                    dismiss()
                }
            }
            SettingsGroup(title: "Mac window") {
                if actions.canResize {
                    SettingsActionRow(systemImage: "arrow.up.left.and.arrow.down.right", title: "Resize Mac window to fit") {
                        model.resizeMacWindowToScene(); dismiss()
                    }
                    .accessibilityIdentifier("action-resize-mac")
                }
                if actions.canMinimise {
                    SettingsActionRow(systemImage: "minus.rectangle", title: "Minimise") { model.macCommand(.minimise); dismiss() }
                        .accessibilityIdentifier("action-minimise")
                }
                if actions.canZoom {
                    SettingsActionRow(systemImage: "plus.magnifyingglass", title: "Zoom") { model.macCommand(.zoom); dismiss() }
                        .accessibilityIdentifier("action-zoom")
                }
                if actions.canExitFullScreen {
                    SettingsActionRow(systemImage: "arrow.down.right.and.arrow.up.left", title: "Exit full screen") {
                        model.macCommand(.exitFullScreen); dismiss()
                    }
                    .accessibilityIdentifier("action-exit-full-screen")
                }
                if actions.canClose {
                    SettingsActionRow(systemImage: "xmark.rectangle", title: "Close Mac window") { model.macCommand(.close); dismiss() }
                        .accessibilityIdentifier("action-close-mac")
                }
                SettingsActionRow(systemImage: "display", title: "Show on full desktop") { dismiss(); openDesktop() }
                    .accessibilityIdentifier("action-show-desktop")
            }
        }
    }
}

/// The menus of the Mac app in this window, as a bottom sheet: a list that opens level by level, and a tap runs the item on the Mac.
///
/// It asks the Mac for the menu when it opens (and again until the Mac answers or a few seconds pass), so it works whether or not the menu
/// had been fetched earlier: a menu asked for before the link was up used to stay empty for the whole session.
@available(iOS 26, *)
struct RemoteMenuSheet: View {
    let model: RemoteWindowSceneModel
    @Environment(\.dismiss) private var dismiss
    @State private var entries: [RemoteMenuEntry] = []
    @State private var isLoading = true

    var body: some View {
        NavigationStack {
            Group {
                if let bundleID = model.focusedBundleID {
                    content(bundleID: bundleID)
                } else {
                    placeholder("No Mac app in focus")
                }
            }
            .navigationTitle("Menus")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
        .chromeSheet()
        .task(id: model.focusedBundleID) { await load() }
        .onChange(of: model.connection?.menuRevision) { _, _ in refresh() }
    }

    @ViewBuilder
    private func content(bundleID: String) -> some View {
        if entries.isEmpty {
            if isLoading {
                ProgressView().controlSize(.large).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                placeholder("No menu available")
            }
        } else {
            List { MenuLevel(entries: entries, bundleID: bundleID, model: model, close: { dismiss() }) }
                .chromeList()
        }
    }

    private func placeholder(_ text: LocalizedStringKey) -> some View {
        Text(text).foregroundStyle(Theme.onChromeSecondary).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func refresh() {
        guard let bundleID = model.focusedBundleID, let connection = model.connection else { return }
        let fresh = connection.menuEntries(bundleID: bundleID)
        if !fresh.isEmpty { entries = fresh; isLoading = false }
    }

    private func load() async {
        guard let bundleID = model.focusedBundleID, let connection = model.connection else { isLoading = false; return }
        entries = connection.menuEntries(bundleID: bundleID)
        isLoading = entries.isEmpty
        // Ask, wait for the answer, ask again: the first request is lost when the link is still coming up.
        for _ in 0..<4 where !Task.isCancelled {
            connection.requestMenu(bundleID: bundleID, force: true)
            for _ in 0..<30 where !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                let fresh = connection.menuEntries(bundleID: bundleID)
                if !fresh.isEmpty { entries = fresh; isLoading = false; return }
            }
        }
        isLoading = false
    }
}

/// One level of a Mac menu: separators split it into sections, a submenu opens the next level, a leaf runs on the Mac.
@available(iOS 26, *)
private struct MenuLevel: View {
    let entries: [RemoteMenuEntry]
    let bundleID: String
    let model: RemoteWindowSceneModel
    let close: () -> Void

    private var sections: [[RemoteMenuEntry]] {
        var groups: [[RemoteMenuEntry]] = [[]]
        for entry in entries {
            if entry.isSeparator {
                if !(groups.last?.isEmpty ?? true) { groups.append([]) }
            } else {
                groups[groups.count - 1].append(entry)
            }
        }
        return groups.filter { !$0.isEmpty }
    }

    var body: some View {
        ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
            Section {
                ForEach(section) { entry in row(entry) }
            }
        }
    }

    @ViewBuilder
    private func row(_ entry: RemoteMenuEntry) -> some View {
        let title = entry.title.isEmpty ? " " : entry.title
        if let children = entry.children {
            NavigationLink {
                List { MenuLevel(entries: children, bundleID: bundleID, model: model, close: close) }
                    .chromeList()
                    .navigationTitle(title)
                    .navigationBarTitleDisplayMode(.inline)
            } label: {
                Text(title).foregroundStyle(Theme.onChrome)
            }
            .disabled(!entry.enabled)
        } else {
            Button {
                Haptics.tap()
                model.pressMenu(bundleID: bundleID, path: entry.path)
                close()
            } label: {
                HStack {
                    Text(title).foregroundStyle(Theme.onChrome)
                    Spacer(minLength: 12)
                    if let shortcut = entry.shortcut, shortcut.input.count == 1 {
                        Text(Self.describe(shortcut)).font(.callout).foregroundStyle(Theme.onChromeSecondary)
                    }
                    if entry.checked { Image(systemName: "checkmark").foregroundStyle(Theme.onChrome) }
                }
                .frame(minHeight: Theme.Size.hit - 12)
                .contentShape(Rectangle())
            }
            .disabled(!entry.enabled)
            .accessibilityIdentifier("menu-item-" + entry.path.map(String.init).joined(separator: "."))
        }
    }

    private static func describe(_ shortcut: MenuShortcut) -> String {
        var text = ""
        if shortcut.modifiers.contains(.control) { text += "⌃" }
        if shortcut.modifiers.contains(.option) { text += "⌥" }
        if shortcut.modifiers.contains(.shift) { text += "⇧" }
        if shortcut.modifiers.contains(.command) { text += "⌘" }
        return text + shortcut.input.uppercased()
    }
}
