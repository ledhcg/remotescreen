import Foundation
import Localization

/// UI strings of SessionKit: the key is the English sentence; translations live in `Resources/vi.lproj/Localizable.strings`.
func tr(_ key: String, _ arguments: CVarArg...) -> String {
    Localization.format(key, bundle: .module, arguments)
}

/// The package's resource bundle, so tests can look up a specific language table.
let localizationBundle: Bundle = .module
