import Foundation
import Localization

/// InputKit UI strings: the key is the English sentence, the translation lives in `Resources/vi.lproj/Localizable.strings`.
func tr(_ key: String, _ arguments: CVarArg...) -> String {
    Localization.format(key, bundle: .module, arguments)
}
