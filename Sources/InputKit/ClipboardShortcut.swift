import Foundation
import RFBKit

/// What to do with the clipboard when the user presses a shortcut on the remote Mac.
public enum ClipboardIntent: Equatable, Sendable {
    /// ⌘C or ⌘X: the Mac is about to have new content, so fetch it to the phone after a moment.
    case copy
    /// ⌘V: the user wants to paste the **phone's** content, so send the phone's clipboard to the Mac BEFORE the `v` key.
    case paste
}

/// Recognizes ⌘C, ⌘X, ⌘V in the outgoing stream of key messages, even when ⌘ and the letter arrive in two separate sends
/// (⌘ latched on the accessory bar, or a hardware keyboard pressing ⌘ and only then `v`).
///
/// Pure logic over `ClientMessage`, knowing nothing about UIKit, so it can be tested with data.
public struct ClipboardShortcutDetector: Sendable {
    public struct Match: Equatable, Sendable {
        /// Position, within the batch of messages just observed, of the letter key press. Sending the clipboard to the Mac must insert **before** this position.
        public var index: Int
        public var intent: ClipboardIntent

        public init(index: Int, intent: ClipboardIntent) {
            self.index = index
            self.intent = intent
        }
    }

    private var commandKeysDown: Set<UInt32> = []

    public init() {}

    /// Letters (lowercase and uppercase, since Shift may be held) for each shortcut.
    private static let intents: [UInt32: ClipboardIntent] = [
        0x63: .copy, 0x43: .copy, // c, C
        0x78: .copy, 0x58: .copy, // x, X (cut also changes the Mac clipboard)
        0x76: .paste, 0x56: .paste, // v, V
    ]

    /// Observes a batch of messages about to be sent, in send order. Keeps ⌘ state across batches.
    public mutating func observe(_ messages: [ClientMessage]) -> [Match] {
        var matches: [Match] = []
        for (index, message) in messages.enumerated() {
            guard case .keyEvent(let isDown, let keysym) = message else { continue }
            if keysym == KeysymMapper.commandLeft || keysym == KeysymMapper.commandRight {
                if isDown { commandKeysDown.insert(keysym) } else { commandKeysDown.remove(keysym) }
            } else if isDown, !commandKeysDown.isEmpty, let intent = Self.intents[keysym] {
                matches.append(Match(index: index, intent: intent))
            }
        }
        return matches
    }

    /// Forget ⌘ state (connection lost, all keys released): prevents a "stuck" ⌘ from turning every later `c` into a copy command.
    public mutating func reset() {
        commandKeysDown.removeAll()
    }
}
