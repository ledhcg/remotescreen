import Foundation
import RFBKit
import Testing
@testable import InputKit

private func down(_ keysym: UInt32) -> ClientMessage { .keyEvent(isDown: true, keysym: keysym) }
private func up(_ keysym: UInt32) -> ClientMessage { .keyEvent(isDown: false, keysym: keysym) }
private let command = KeysymMapper.commandLeft

@Suite("ClipboardShortcutDetector")
struct ClipboardShortcutTests {
    @Test(arguments: [
        (UInt32(0x63), ClipboardIntent.copy), (0x43, .copy), (0x78, .copy), (0x58, .copy), (0x76, .paste), (0x56, .paste),
    ])
    func commandPlusLetterInOneBatch(letter: UInt32, intent: ClipboardIntent) {
        var detector = ClipboardShortcutDetector()
        let matches = detector.observe([down(command), down(letter), up(letter), up(command)])
        #expect(matches == [.init(index: 1, intent: intent)])
    }

    /// ⌘ latched on the accessory bar: ⌘ arrives in this batch, the letter `c` in a later one (many seconds later).
    @Test func commandAndLetterInSeparateBatches() {
        var detector = ClipboardShortcutDetector()
        #expect(detector.observe([down(command)]).isEmpty)
        #expect(detector.observe([down(0x76), up(0x76), up(command)]) == [.init(index: 0, intent: .paste)])
        #expect(detector.observe([down(0x76), up(0x76)]).isEmpty, "⌘ was released, `v` is no longer a shortcut")
    }

    @Test func plainLettersAreNotShortcuts() {
        var detector = ClipboardShortcutDetector()
        #expect(detector.observe([down(0x63), up(0x63), down(0x76), up(0x76)]).isEmpty)
    }

    @Test func otherModifiersDoNotTrigger() {
        var detector = ClipboardShortcutDetector()
        // Control+C, Option+V: not the Mac copy/paste shortcuts.
        #expect(detector.observe([down(0xFFE3), down(0x63), up(0x63), up(0xFFE3)]).isEmpty)
        #expect(detector.observe([down(0xFFE9), down(0x76), up(0x76), up(0xFFE9)]).isEmpty)
    }

    @Test func otherLettersWithCommandDoNotTrigger() {
        var detector = ClipboardShortcutDetector()
        #expect(detector.observe([down(command), down(0x61), up(0x61), down(0x7A), up(0x7A), up(command)]).isEmpty)
    }

    @Test func releaseOfTheLetterIsNotAShortcut() {
        var detector = ClipboardShortcutDetector()
        #expect(detector.observe([down(command)]).isEmpty)
        #expect(detector.observe([up(0x63)]).isEmpty, "only the key-down counts, the release does not")
    }

    @Test func rightCommandWorksAndBothMustBeReleased() {
        var detector = ClipboardShortcutDetector()
        let right = KeysymMapper.commandRight
        #expect(detector.observe([down(command), down(right), up(command)]).isEmpty)
        #expect(detector.observe([down(0x63)]) == [.init(index: 0, intent: .copy)], "right ⌘ is still held")
        _ = detector.observe([up(right)])
        #expect(detector.observe([down(0x63)]).isEmpty)
    }

    @Test func matchesCarryTheIndexSoTheClipboardGoesBeforeTheKey() {
        var detector = ClipboardShortcutDetector()
        let batch = [down(0x20), up(0x20), down(command), down(0x76), up(0x76), up(command)]
        #expect(detector.observe(batch) == [.init(index: 3, intent: .paste)])
    }

    @Test func twoShortcutsInOneBatchAreBothFound() {
        var detector = ClipboardShortcutDetector()
        let batch = [down(command), down(0x63), up(0x63), down(0x76), up(0x76), up(command)]
        #expect(detector.observe(batch) == [.init(index: 1, intent: .copy), .init(index: 3, intent: .paste)])
    }

    /// A stuck ⌘ (connection lost midway) must not turn every later letter `c` into a copy command.
    @Test func resetForgetsAStuckCommand() {
        var detector = ClipboardShortcutDetector()
        _ = detector.observe([down(command)])
        detector.reset()
        #expect(detector.observe([down(0x63)]).isEmpty)
    }

    @Test func pointerAndOtherMessagesAreIgnoredButKeepIndexesAligned() {
        var detector = ClipboardShortcutDetector()
        let batch: [ClientMessage] = [.pointerEvent(buttons: 0, x: 1, y: 2), down(command), .clientCutText("x"), down(0x76)]
        #expect(detector.observe(batch) == [.init(index: 3, intent: .paste)])
    }
}
