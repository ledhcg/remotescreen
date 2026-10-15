import Foundation

/// Modifier keys currently held. Mirrors the meaning of `UIKeyModifierFlags` without depending on UIKit.
public struct KeyModifiers: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let shift = KeyModifiers(rawValue: 1 << 0)
    public static let control = KeyModifiers(rawValue: 1 << 1)
    public static let option = KeyModifiers(rawValue: 1 << 2)
    public static let command = KeyModifiers(rawValue: 1 << 3)
}

/// One press or release of a physical key, decoupled from `UIPress`.
public struct KeyPress: Sendable, Equatable {
    /// HID Usage code (Keyboard/Keypad page), for example `0x28` is Return. This identifies the physical key.
    public var hidUsage: Int
    /// Character the key produces, with modifiers applied (Shift gives uppercase, and so on).
    public var characters: String
    /// Character the key produces ignoring modifiers, except Shift.
    public var charactersIgnoringModifiers: String
    public var modifiers: KeyModifiers
    public var isDown: Bool

    public init(hidUsage: Int, characters: String = "", charactersIgnoringModifiers: String = "",
                modifiers: KeyModifiers = [], isDown: Bool) {
        self.hidUsage = hidUsage
        self.characters = characters
        self.charactersIgnoringModifiers = charactersIgnoringModifiers
        self.modifiers = modifiers
        self.isDown = isDown
    }
}

/// Converts keys to X11 keysyms (`keysymdef.h`), which the RFB protocol uses to say "which key".
public enum KeysymMapper {
    /// How to name the keysym for the Command key. **Not yet verified against Apple's server**: it is unclear whether the server reads Command as
    /// `Meta_L`, `Super_L` or `Alt_L`. Kept in one place so it can change without touching the logic.
    public static let commandLeft: UInt32 = 0xFFE7 // Meta_L
    public static let commandRight: UInt32 = 0xFFE8 // Meta_R

    /// Keys that print no character, looked up by HID Usage.
    static let specialKeys: [Int: UInt32] = {
        var table: [Int: UInt32] = [
            0x28: 0xFF0D, // Return
            0x29: 0xFF1B, // Escape
            0x2A: 0xFF08, // Backspace
            0x2B: 0xFF09, // Tab
            0x39: 0xFFE5, // Caps Lock
            0x46: 0xFF61, // Print Screen
            0x47: 0xFF14, // Scroll Lock
            0x48: 0xFF13, // Pause
            0x49: 0xFF63, // Insert
            0x4A: 0xFF50, // Home
            0x4B: 0xFF55, // Page Up
            0x4C: 0xFFFF, // Delete (forward delete)
            0x4D: 0xFF57, // End
            0x4E: 0xFF56, // Page Down
            0x4F: 0xFF53, // Right
            0x50: 0xFF51, // Left
            0x51: 0xFF54, // Down
            0x52: 0xFF52, // Up
            0xE0: 0xFFE3, // Left Control
            0xE1: 0xFFE1, // Left Shift
            0xE2: 0xFFE9, // Left Option (Alt_L)
            0xE3: commandLeft,
            0xE4: 0xFFE4, // Right Control
            0xE5: 0xFFE2, // Right Shift
            0xE6: 0xFFEA, // Right Option (Alt_R)
            0xE7: commandRight,
        ]
        for index in 0..<12 { table[0x3A + index] = UInt32(0xFFBE + index) } // F1...F12
        for index in 0..<12 { table[0x68 + index] = UInt32(0xFFCA + index) } // F13...F24
        return table
    }()

    /// Keysym for a press, or `nil` if the key produces nothing sendable.
    public static func keysym(for press: KeyPress) -> UInt32? {
        if let special = specialKeys[press.hidUsage] { return special }

        // With Control, Command or Option the character has been altered: turned into a control code (Ctrl+C is 0x03), unstable
        // (Command), or pre-composed (Option+X is `≈`). Use the key's base character and let the remote Mac compose it, like a real Mac
        // keyboard: Ctrl+C sends `Control` then `c`, Option+X sends `Alt` then `x`.
        let text = press.modifiers.isDisjoint(with: [.control, .command, .option]) ? press.characters : press.charactersIgnoringModifiers
        guard let scalar = text.unicodeScalars.first else { return nil }
        return keysym(forUnicode: scalar)
    }

    /// Key sequence for ⌘ plus a character: Command down, character down then up, Command up. Used for combinations that iPadOS keeps for
    /// itself (such as ⌘F) and so never reach `pressesBegan`; `nil` if the character cannot be converted to a keysym.
    ///
    /// - Parameter commandAlreadyDown: ⌘ has already been sent down (the user is holding a real ⌘, or ⌘ is latched on the accessory bar).
    /// In that case only the character is sent: pressing then releasing ⌘ ourselves would make the Mac see ⌘ released while the finger still holds it,
    /// and the next key (⌘G, ⌘V) would turn into a plain letter.
    public static func commandChord(_ character: Character, commandAlreadyDown: Bool = false) -> [InputIntent]? {
        guard let scalar = String(character).lowercased().unicodeScalars.first, let keysym = keysym(forUnicode: scalar) else { return nil }
        if commandAlreadyDown { return InputIntent.tap(keysym) }
        let command = StickyModifier.command.macKeyCode
        return [
            .key(commandLeft, macKeyCode: command, isDown: true), .key(keysym, isDown: true),
            .key(keysym, isDown: false), .key(commandLeft, macKeyCode: command, isDown: false),
        ]
    }

    /// Latin-1 uses the Unicode code point directly as the keysym. Other characters use the `0x01000000 + Unicode code point` form that X11 defines.
    static func keysym(forUnicode scalar: Unicode.Scalar) -> UInt32? {
        switch scalar.value {
        case 0x20...0x7E, 0xA0...0xFF: scalar.value
        case 0...0x1F, 0x7F...0x9F: nil // control characters
        default: 0x0100_0000 + scalar.value
        }
    }
}

/// Key repeat timing while held. A real Mac keyboard repeats after about 0.4 seconds, then about 15 times per second.
public enum KeyRepeat {
    public static let initialDelay: Duration = .milliseconds(400)
    public static let interval: Duration = .milliseconds(65)
    /// Safety net: stop repeating after this long (the release may have been received by another view, so we never see
    /// it). Nobody holds a key for 30 seconds, while a Backspace that repeats forever would wipe out a document on the Mac.
    public static let maximumDuration: Duration = .seconds(30)
}

/// A held key that the remote machine should see repeating.
public struct RepeatingKey: Equatable, Sendable {
    public var hidUsage: Int
    public var keysym: UInt32
}

/// Tracks held keys so that every press gets exactly one matching release.
///
/// The release must use the **same keysym as the press**: if the user releases Shift before the letter, the character
/// has changed from `A` to `a` by the time of release, and the server would see `A` stuck forever.
public struct KeyboardState: Sendable {
    private var held: [(hidUsage: Int, keysym: UInt32)] = []

    public init() {}

    public var heldKeyCount: Int { held.count }

    /// Whether any held key has already sent this keysym (for example left ⌘ 0xFFE7).
    public func isHolding(keysym: UInt32) -> Bool {
        held.contains { $0.keysym == keysym }
    }

    /// The key to repeat right now, or `nil`. The remote machine does not repeat keys we send (only a physical keyboard generates repeats), and iPadOS
    /// does not resend `pressesBegan` for a held key either, so holding Backspace or an arrow would produce a single stroke without manual repeat.
    ///
    /// Like a real keyboard: only the **most recently** pressed key repeats, releasing it stops repeating (earlier keys do not resume), and modifiers
    /// (Shift, Control, Option, Command, Caps Lock) do not repeat.
    public private(set) var repeating: RepeatingKey?

    private static func isRepeatable(_ hidUsage: Int) -> Bool {
        !(0xE0...0xE7).contains(hidUsage) && hidUsage != 0x39
    }

    public mutating func handle(_ press: KeyPress) -> [InputIntent] {
        if press.isDown {
            guard let keysym = KeysymMapper.keysym(for: press) else { return [] }
            if let index = held.firstIndex(where: { $0.hidUsage == press.hidUsage }) {
                held[index].keysym = keysym // key repeat: resend the press, do not add a new held entry
                // If the OS delivers the repeat itself, leave it to the OS and do not stack another on top.
                if repeating?.hidUsage == press.hidUsage { repeating = nil }
            } else {
                held.append((press.hidUsage, keysym))
                repeating = Self.isRepeatable(press.hidUsage) ? RepeatingKey(hidUsage: press.hidUsage, keysym: keysym) : nil
            }
            return [.key(keysym, isDown: true)]
        }
        guard let index = held.firstIndex(where: { $0.hidUsage == press.hidUsage }) else { return [] }
        if repeating?.hidUsage == press.hidUsage { repeating = nil }
        let keysym = held.remove(at: index).keysym
        return [.key(keysym, isDown: false)]
    }

    /// Releases every held key, in reverse order of pressing. Call on focus loss, backgrounding or disconnect,
    /// so the remote machine is not left with stuck keys (for example Command never released).
    public mutating func releaseAll() -> [InputIntent] {
        defer {
            held.removeAll()
            repeating = nil
        }
        return held.reversed().map { .key($0.keysym, isDown: false) }
    }

    /// Types a string (for the on-screen keyboard) as one text intent; empty if nothing in it can be sent.
    /// The RFB encoder presses then releases each character's keysym; newline sends Return, Tab sends Tab. Characters that cannot be
    /// converted to a keysym are skipped.
    public static func typing(_ text: String) -> [InputIntent] {
        typingKeysyms(text).isEmpty ? [] : [.text(text)]
    }

    /// Keysyms for the characters of `text` that can be sent as typed keys, in order.
    public static func typingKeysyms(_ text: String) -> [UInt32] {
        text.unicodeScalars.compactMap { scalar in
            switch scalar {
            case "\n", "\r": 0xFF0D
            case "\t": 0xFF09
            default: KeysymMapper.keysym(forUnicode: scalar)
            }
        }
    }
}
