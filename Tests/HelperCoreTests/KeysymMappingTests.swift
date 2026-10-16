#if os(macOS)
import Foundation
import Testing
@testable import HelperCore

@Suite(.timeLimit(.minutes(2))) struct KeysymMappingTests {
    @Test func lettersAndDigitsMapToTheUSLayout() {
        #expect(KeysymMapping.resolve(0x61) == .key(keycode: 0, shift: false))   // a
        #expect(KeysymMapping.resolve(0x41) == .key(keycode: 0, shift: true))    // A
        #expect(KeysymMapping.resolve(0x7A) == .key(keycode: 6, shift: false))   // z
        #expect(KeysymMapping.resolve(0x31) == .key(keycode: 18, shift: false))  // 1
        #expect(KeysymMapping.resolve(0x21) == .key(keycode: 18, shift: true))   // !
        #expect(KeysymMapping.resolve(0x20) == .key(keycode: 49, shift: false))  // space
        #expect(KeysymMapping.resolve(0x3F) == .key(keycode: 44, shift: true))   // ?
    }

    @Test func everyPrintableASCIIKeysymHasAKey() {
        for keysym in UInt32(0x20)...0x7E {
            guard case .key = KeysymMapping.resolve(keysym) else {
                Issue.record("no key for \(keysym)")
                continue
            }
        }
    }

    @Test func controlKeysMap() {
        #expect(KeysymMapping.resolve(0xFF0D) == .key(keycode: 36, shift: false))  // Return
        #expect(KeysymMapping.resolve(0xFF1B) == .key(keycode: 53, shift: false))  // Escape
        #expect(KeysymMapping.resolve(0xFF51) == .key(keycode: 123, shift: false)) // Left
        #expect(KeysymMapping.resolve(0xFFBE) == .key(keycode: 122, shift: false)) // F1
        #expect(KeysymMapping.resolve(0xFFEB) == .key(keycode: 55, shift: false))  // Super_L is Command
    }

    @Test func otherPrintableCharactersAreTyped() {
        #expect(KeysymMapping.resolve(0xE9) == .text("é"))            // Latin-1 keysym
        #expect(KeysymMapping.resolve(0x0100_1EA1) == .text("ạ"))     // Unicode keysym
        #expect(KeysymMapping.resolve(0x0101_F600) == .text("😀"))
    }

    @Test func unknownAndNonPrintableKeysymsAreDropped() {
        for keysym: UInt32 in [0, 0x1F, 0x7F, 0x80, 0x9F, 0xFE50, 0xFF7F, 0xFFFFFF, 0x0100_0000, 0x0100_D800, 0x0111_0000, .max] {
            #expect(KeysymMapping.resolve(keysym) == .drop, "keysym \(keysym)")
        }
    }
}
#endif
