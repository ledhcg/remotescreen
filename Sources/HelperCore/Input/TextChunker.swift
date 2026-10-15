#if os(macOS)
import Foundation

/// Splits text for `CGEventKeyboardSetUnicodeString`, which accepts at most about 20 UTF-16 units per event.
public enum TextChunker {
    public static let maxUTF16Units = 20

    /// Chunks of at most `limit` UTF-16 units. Chunks break between grapheme clusters when possible (so a base letter and its
    /// combining marks, or an emoji sequence, stay together); a cluster longer than `limit` is split between Unicode scalars,
    /// and never inside a surrogate pair.
    public static func chunks(_ text: String, limit: Int = maxUTF16Units) -> [String] {
        precondition(limit >= 2, "a surrogate pair needs two units")
        var result: [String] = []
        var current = String.UnicodeScalarView()
        var currentUnits = 0
        func flush() {
            if !current.isEmpty { result.append(String(current)); current = .init(); currentUnits = 0 }
        }
        for character in text {
            let units = character.utf16.count
            if units <= limit {
                if currentUnits + units > limit { flush() }
                current.append(contentsOf: character.unicodeScalars)
                currentUnits += units
            } else {
                flush()
                for scalar in character.unicodeScalars {
                    let scalarUnits = scalar.utf16.count
                    if currentUnits + scalarUnits > limit { flush() }
                    current.append(scalar)
                    currentUnits += scalarUnits
                }
                flush()
            }
        }
        flush()
        return result
    }
}
#endif
