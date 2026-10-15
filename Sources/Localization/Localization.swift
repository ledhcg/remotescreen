import Foundation
import os

/// Looks up UI strings by language. English is the source language: **the English sentence itself is the key**, so a missing
/// translation still shows readable English. Translations live in each package's `Resources/<code>.lproj/Localizable.strings`.
///
/// Every package has a thin `tr(_:_:)` helper that calls `Localization.format(_:bundle: .module, _:)`.
public enum Localization {
    private static let forced = OSAllocatedUnfairLock<String?>(
        initialState: ProcessInfo.processInfo.environment["SCREON_LANGUAGE"]
    )

    /// Forces a language (for example `"en"` or `"vi"`) instead of following the system language. Tests set `"en"` so results do
    /// not depend on the machine running them. Can also be set with the `SCREON_LANGUAGE` environment variable.
    public static var forcedLanguage: String? {
        get { forced.withLock { $0 } }
        set { forced.withLock { $0 = newValue } }
    }

    /// The translation of `key` (no formatting). Pass `language` to look up one table explicitly, without touching the shared
    /// `forcedLanguage` (which is process-wide).
    public static func string(_ key: String, bundle: Bundle, language: String? = nil) -> String {
        guard let language = language ?? forcedLanguage else {
            return bundle.localizedString(forKey: key, value: key, table: nil)
        }
        if language == "en" { return key } // source language: the key is the English sentence
        guard let path = bundle.path(forResource: language, ofType: "lproj"), let localized = Bundle(path: path) else { return key }
        return localized.localizedString(forKey: key, value: key, table: nil)
    }

    /// Like `string`, then substitutes `arguments` for `%@`, `%lld`, `%d`... in order (use `%1$@` when a translation reorders them).
    public static func format(_ key: String, bundle: Bundle, _ arguments: [CVarArg]) -> String {
        let template = string(key, bundle: bundle)
        return arguments.isEmpty ? template : String(format: template, locale: Locale.current, arguments: arguments)
    }
}
