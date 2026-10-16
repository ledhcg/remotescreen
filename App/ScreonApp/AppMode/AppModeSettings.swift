import Foundation
import WindowKit

/// App Mode preferences, kept in `UserDefaults` (the keys are also used by `@AppStorage` in the settings sheet).
enum AppModeSettings {
    static let openStyleKey = "appMode.openStyle"
    static let newWindowPolicyKey = "appMode.newWindowPolicy"
    static let closeShortcutKey = "appMode.closeShortcut"

    static var openStyle: AppOpenStyle {
        UserDefaults.standard.string(forKey: openStyleKey).flatMap(AppOpenStyle.init(rawValue:)) ?? .separateWindows
    }

    static var newWindowPolicy: NewWindowPolicy {
        UserDefaults.standard.string(forKey: newWindowPolicyKey).flatMap(NewWindowPolicy.init(rawValue:)) ?? .autoOpen
    }

    static var closeShortcut: CloseShortcutPolicy {
        UserDefaults.standard.string(forKey: closeShortcutKey).flatMap(CloseShortcutPolicy.init(rawValue:)) ?? .closeIPadWindow
    }
}

extension AppOpenStyle {
    var title: String {
        switch self {
        case .separateWindows: String(localized: "Separate windows")
        case .tabs: String(localized: "Tabs in one window")
        }
    }
}

extension NewWindowPolicy {
    var title: String {
        switch self {
        case .autoOpen: String(localized: "Open in a new window")
        case .badge: String(localized: "Only show a badge")
        }
    }
}

extension CloseShortcutPolicy {
    var title: String {
        switch self {
        case .closeIPadWindow: String(localized: "Closes the iPad window")
        case .sendToMac: String(localized: "Is sent to the Mac")
        }
    }
}
