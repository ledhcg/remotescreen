import Foundation
import Localization

/// UI strings of ConnectionKit: the key is the English sentence; translations live in `Resources/vi.lproj/Localizable.strings`.
func tr(_ key: String, _ arguments: CVarArg...) -> String {
    Localization.format(key, bundle: .module, arguments)
}
