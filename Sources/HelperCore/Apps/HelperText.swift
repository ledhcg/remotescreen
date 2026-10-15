#if os(macOS)
import Foundation

/// Bounds for strings that come from other processes (window titles, app and menu names) before they go on the wire.
enum HelperText {
    /// `string` cut at a character boundary so that its UTF-8 form is at most `maxBytes` long.
    static func bounded(_ string: String, maxBytes: Int) -> String {
        guard string.utf8.count > maxBytes else { return string }
        var result = ""
        var used = 0
        for character in string {
            let size = String(character).utf8.count
            if used + size > maxBytes { break }
            result.append(character)
            used += size
        }
        return result
    }
}
#endif
