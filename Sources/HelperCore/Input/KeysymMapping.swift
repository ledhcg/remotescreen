#if os(macOS)
import Foundation

/// What to do with a key event that has a keysym but no Mac virtual key code (`LinkKeyEvent.noKeycode`).
public enum KeysymResolution: Sendable, Equatable {
    /// Press this Mac virtual key. `shift` is set when the character needs Shift on a US layout.
    case key(keycode: UInt16, shift: Bool)
    /// A printable character without a US-layout key: type it as Unicode text on key down, nothing on key up.
    case text(String)
    /// Unknown and not printable: dropped.
    case drop
}

/// Keysym (X11 numbering) to Mac virtual key code, for the US layout, with a Unicode fallback for printable characters.
/// Pure data; `kVK_*` values are written as numbers so this file needs no Carbon import.
public enum KeysymMapping {
    public static func resolve(_ keysym: UInt32) -> KeysymResolution {
        if let code = functionKeys[keysym] { return .key(keycode: code, shift: false) }
        if let entry = ascii[keysym] { return .key(keycode: entry.code, shift: entry.shift) }
        if let scalar = printableScalar(keysym) { return .text(String(scalar)) }
        return .drop
    }

    /// The Unicode character a keysym stands for, when it is a printable one.
    static func printableScalar(_ keysym: UInt32) -> Unicode.Scalar? {
        let value: UInt32
        switch keysym {
        case 0x20...0x7E, 0xA0...0xFF: value = keysym  // ASCII and Latin-1 keysyms equal their code points
        case 0x0100_0000...0x0110_FFFF: value = keysym - 0x0100_0000  // X11 Unicode keysyms
        default: return nil
        }
        guard let scalar = Unicode.Scalar(value) else { return nil }
        switch scalar.properties.generalCategory {
        case .control, .format, .surrogate, .privateUse, .unassigned, .lineSeparator, .paragraphSeparator: return nil
        default: return scalar
        }
    }

    private static let functionKeys: [UInt32: UInt16] = [
        0xFF0D: 36, 0xFF8D: 76, 0xFF09: 48, 0xFF08: 51, 0xFF1B: 53, 0xFFFF: 117,
        0xFF50: 115, 0xFF57: 119, 0xFF55: 116, 0xFF56: 121,
        0xFF51: 123, 0xFF52: 126, 0xFF53: 124, 0xFF54: 125,
        0xFFBE: 122, 0xFFBF: 120, 0xFFC0: 99, 0xFFC1: 118, 0xFFC2: 96, 0xFFC3: 97,
        0xFFC4: 98, 0xFFC5: 100, 0xFFC6: 101, 0xFFC7: 109, 0xFFC8: 103, 0xFFC9: 111,
        0xFFE1: 56, 0xFFE2: 60, 0xFFE3: 59, 0xFFE4: 62, 0xFFE5: 57,
        0xFFE9: 58, 0xFFEA: 61, 0xFFEB: 55, 0xFFEC: 54,
    ]

    /// US layout: character to key code and whether Shift is needed.
    private static let ascii: [UInt32: (code: UInt16, shift: Bool)] = {
        var table: [UInt32: (code: UInt16, shift: Bool)] = [:]
        let letters: [(Character, UInt16)] = [
            ("a", 0), ("s", 1), ("d", 2), ("f", 3), ("h", 4), ("g", 5), ("z", 6), ("x", 7), ("c", 8), ("v", 9), ("b", 11), ("q", 12),
            ("w", 13), ("e", 14), ("r", 15), ("y", 16), ("t", 17), ("o", 31), ("u", 32), ("i", 34), ("p", 35), ("l", 37), ("j", 38),
            ("k", 40), ("n", 45), ("m", 46),
        ]
        for (character, code) in letters {
            let lower = character.asciiValue.map(UInt32.init) ?? 0
            table[lower] = (code, false)
            table[lower - 0x20] = (code, true)
        }
        // Unshifted and shifted characters of the other keys.
        let pairs: [(Character, Character, UInt16)] = [
            ("1", "!", 18), ("2", "@", 19), ("3", "#", 20), ("4", "$", 21), ("6", "^", 22), ("5", "%", 23), ("=", "+", 24),
            ("9", "(", 25), ("7", "&", 26), ("-", "_", 27), ("8", "*", 28), ("0", ")", 29), ("]", "}", 30), ("[", "{", 33),
            ("'", "\"", 39), (";", ":", 41), ("\\", "|", 42), (",", "<", 43), ("/", "?", 44), (".", ">", 47), ("`", "~", 50),
        ]
        for (plain, shifted, code) in pairs {
            if let p = plain.asciiValue { table[UInt32(p)] = (code, false) }
            if let s = shifted.asciiValue { table[UInt32(s)] = (code, true) }
        }
        table[0x20] = (49, false)
        return table
    }()
}
#endif
