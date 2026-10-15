import Foundation
import RFBKit
import Testing
@testable import InputKit

private func down(_ hid: Int, _ characters: String = "", ignoring: String? = nil, _ modifiers: KeyModifiers = []) -> KeyPress {
    KeyPress(hidUsage: hid, characters: characters, charactersIgnoringModifiers: ignoring ?? characters, modifiers: modifiers, isDown: true)
}

private func up(_ hid: Int) -> KeyPress {
    KeyPress(hidUsage: hid, isDown: false)
}

private func key(_ isDown: Bool, _ keysym: UInt32) -> ClientMessage { .keyEvent(isDown: isDown, keysym: keysym) }

/// Giá trị kỳ vọng lấy từ `keysymdef.h` của X11, không sinh từ chính code đang test.
@Suite("KeysymMapper")
struct KeysymMapperTests {
    @Test func printableLatin1UsesTheCodePointAsTheKeysym() {
        #expect(KeysymMapper.keysym(for: down(0x04, "a")) == 0x61)
        #expect(KeysymMapper.keysym(for: down(0x04, "A")) == 0x41)
        #expect(KeysymMapper.keysym(for: down(0x2C, " ")) == 0x20)
        #expect(KeysymMapper.keysym(for: down(0, "é")) == 0xE9) // U+00E9 nằm trong Latin-1
    }

    @Test func charactersOutsideLatin1UseTheUnicodeKeysymRange() {
        #expect(KeysymMapper.keysym(for: down(0, "đ")) == 0x0100_0111) // U+0111, chữ tiếng Việt
        #expect(KeysymMapper.keysym(for: down(0, "ệ")) == 0x0100_1EC7) // U+1EC7
        #expect(KeysymMapper.keysym(for: down(0, "😀")) == 0x0101_F600)
    }

    /// Các biên của dải Latin-1: sai lệch một đơn vị ở đây sẽ làm hỏng đúng ký tự ở mép dải mà test thông thường không chạm tới.
    @Test(arguments: [
        (UInt32(0x1F), Optional<UInt32>.none), // ký tự điều khiển cuối trước dấu cách
        (0x20, 0x20), // dấu cách, đầu dải ASCII in được
        (0x7E, 0x7E), // '~', cuối dải ASCII in được
        (0x7F, nil), // DEL
        (0x9F, nil), // ký tự điều khiển C1 cuối cùng
        (0xA0, 0xA0), // dấu cách không ngắt, đầu dải Latin-1 phía trên
        (0xFF, 0xFF), // 'ÿ', cuối dải Latin-1
        (0x100, 0x0100_0100), // ngay trên dải Latin-1 phải sang dạng Unicode keysym
    ])
    func latin1BoundariesAreExact(codePoint: UInt32, expected: UInt32?) throws {
        let scalar = try #require(Unicode.Scalar(codePoint))
        #expect(KeysymMapper.keysym(forUnicode: scalar) == expected, "U+\(String(codePoint, radix: 16, uppercase: true))")
    }

    @Test func controlCharactersAndEmptyStringsProduceNothing() {
        #expect(KeysymMapper.keysym(for: down(0, "\u{03}")) == nil)
        #expect(KeysymMapper.keysym(for: down(0, "\u{7F}")) == nil)
        #expect(KeysymMapper.keysym(for: down(0, "")) == nil)
    }

    /// Mac từ xa tự soạn Option+X thành `≈`. Nếu app gửi sẵn `≈` kèm Option đang giữ thì Mac thấy "Option+≈". Đo trên iPad
    /// thật qua Device Hub: Option+X gửi `0x1002248` thay vì `x`.
    @Test func optionSendsTheBaseKeyNotTheComposedCharacter() {
        #expect(KeysymMapper.keysym(for: down(0x1B, "≈", ignoring: "x", .option)) == 0x78)
        #expect(KeysymMapper.keysym(for: down(0x08, "´", ignoring: "e", .option)) == 0x65) // dead key Option+E
        #expect(KeysymMapper.keysym(for: down(0x1F, "€", ignoring: "@", [.option, .shift])) == 0x40)
    }

    @Test func shiftAloneStillSendsTheShiftedCharacter() {
        // Không đổi hành vi đã đo trên thiết bị thật: Shift+C gửi Shift_L rồi `C` (0x43).
        #expect(KeysymMapper.keysym(for: down(0x06, "C", ignoring: "c", .shift)) == 0x43)
    }

    @Test func controlAndCommandUseTheUnmodifiedCharacter() {
        // Ctrl+C: iOS có thể báo ký tự là 0x03; ta phải gửi chữ 'c' cùng với phím Control.
        #expect(KeysymMapper.keysym(for: down(0x06, "\u{03}", ignoring: "c", .control)) == 0x63)
        #expect(KeysymMapper.keysym(for: down(0x06, "ç", ignoring: "c", .command)) == 0x63)
        // Option cũng dùng ký tự gốc: Mac từ xa tự soạn Option+a thành "å", người gõ vẫn nhận đúng điều họ muốn,
        // và các phím tắt dùng Option hoạt động. Xem `optionSendsTheBaseKeyNotTheComposedCharacter`.
        #expect(KeysymMapper.keysym(for: down(0x04, "å", ignoring: "a", .option)) == 0x61)
    }

    @Test(arguments: [
        (0x28, UInt32(0xFF0D)), // Return
        (0x29, 0xFF1B), // Escape
        (0x2A, 0xFF08), // Backspace
        (0x2B, 0xFF09), // Tab
        (0x4C, 0xFFFF), // Delete tới
        (0x4A, 0xFF50), (0x4D, 0xFF57), // Home, End
        (0x4B, 0xFF55), (0x4E, 0xFF56), // Page Up, Page Down
        (0x50, 0xFF51), (0x52, 0xFF52), (0x4F, 0xFF53), (0x51, 0xFF54), // Trái, Lên, Phải, Xuống
        (0x3A, 0xFFBE), (0x45, 0xFFC9), // F1, F12
        (0x68, 0xFFCA), // F13
    ])
    func specialKeysFollowTheKeysymTable(hid: Int, keysym: UInt32) {
        #expect(KeysymMapper.keysym(for: down(hid)) == keysym)
    }

    @Test func specialKeysIgnoreWhateverCharactersTheSystemReports() {
        #expect(KeysymMapper.keysym(for: down(0x28, "\r")) == 0xFF0D)
        #expect(KeysymMapper.keysym(for: down(0x50, "\u{F702}")) == 0xFF51) // mũi tên trái có thể báo ký tự riêng của Apple
    }

    @Test func modifierKeysMapToTheirKeysyms() {
        #expect(KeysymMapper.keysym(for: down(0xE0)) == 0xFFE3) // Control trái
        #expect(KeysymMapper.keysym(for: down(0xE1)) == 0xFFE1) // Shift trái
        #expect(KeysymMapper.keysym(for: down(0xE2)) == 0xFFE9) // Option trái = Alt_L
        #expect(KeysymMapper.keysym(for: down(0xE3)) == KeysymMapper.commandLeft)
        #expect(KeysymMapper.keysym(for: down(0xE5)) == 0xFFE2) // Shift phải
    }
}

@Suite("KeyboardState")
struct KeyboardStateTests {
    @Test func pressAndReleaseAreBalanced() {
        var state = KeyboardState()
        #expect(state.handle(down(0x04, "a")) == [key(true, 0x61)])
        #expect(state.heldKeyCount == 1)
        #expect(state.handle(up(0x04)) == [key(false, 0x61)])
        #expect(state.heldKeyCount == 0)
    }

    @Test func releaseUsesTheSameKeysymAsThePress() {
        // Nhấn Shift, nhấn A (ra 'A'), NHẢ SHIFT TRƯỚC, rồi nhả A. Lúc nhả, ký tự của phím đã là 'a'
        // nhưng ta phải nhả đúng keysym 'A' đã nhấn, nếu không server thấy 'A' kẹt mãi.
        var state = KeyboardState()
        _ = state.handle(down(0xE1))
        _ = state.handle(down(0x04, "A", ignoring: "a", .shift))
        _ = state.handle(up(0xE1))
        #expect(state.handle(KeyPress(hidUsage: 0x04, characters: "a", isDown: false)) == [key(false, 0x41)])
    }

    @Test func releasingAKeyThatWasNeverPressedSendsNothing() {
        var state = KeyboardState()
        #expect(state.handle(up(0x04)).isEmpty)
    }

    @Test func autoRepeatDoesNotAddASecondHeldEntry() {
        var state = KeyboardState()
        _ = state.handle(down(0x04, "a"))
        #expect(state.handle(down(0x04, "a")) == [key(true, 0x61)])
        #expect(state.heldKeyCount == 1)
        #expect(state.handle(up(0x04)) == [key(false, 0x61)])
        #expect(state.handle(up(0x04)).isEmpty) // chỉ nhả một lần
    }

    @Test func releaseAllFreesEverythingInReverseOrder() {
        var state = KeyboardState()
        _ = state.handle(down(0xE3)) // Command
        _ = state.handle(down(0xE1)) // Shift
        _ = state.handle(down(0x04, "A", ignoring: "a", [.command, .shift]))
        #expect(state.releaseAll() == [key(false, 0x61), key(false, 0xFFE1), key(false, KeysymMapper.commandLeft)])
        #expect(state.heldKeyCount == 0)
        #expect(state.releaseAll().isEmpty)
    }

    @Test func unmappableKeyProducesNothingAndIsNotTracked() {
        var state = KeyboardState()
        #expect(state.handle(down(0x99, "")).isEmpty)
        #expect(state.heldKeyCount == 0)
    }

    @Test func typingProducesPressAndReleasePerCharacter() {
        #expect(KeyboardState.typing("Aé\n\t") == [
            key(true, 0x41), key(false, 0x41),
            key(true, 0xE9), key(false, 0xE9),
            key(true, 0xFF0D), key(false, 0xFF0D),
            key(true, 0xFF09), key(false, 0xFF09),
        ])
        #expect(KeyboardState.typing("đ") == [key(true, 0x0100_0111), key(false, 0x0100_0111)])
        #expect(KeyboardState.typing("").isEmpty)
    }
}

/// Phím giữ phải lặp như bàn phím Mac thật: iPadOS không lặp giúp, máy từ xa cũng không.
@Suite("KeyboardState: lặp phím khi giữ")
struct KeyRepeatTests {
    private let a = 0x04, b = 0x05, shift = 0xE1, command = 0xE3, capsLock = 0x39, backspace = 0x2A, right = 0x4F

    @Test func aHeldPlainKeyRepeatsUntilReleased() {
        var state = KeyboardState()
        #expect(state.repeating == nil)
        _ = state.handle(down(a, "a"))
        #expect(state.repeating == RepeatingKey(hidUsage: a, keysym: 0x61))
        _ = state.handle(up(a))
        #expect(state.repeating == nil)
    }

    @Test func specialKeysRepeatToo() {
        // Backspace và mũi tên là hai phím giữ nhiều nhất khi sửa văn bản.
        var state = KeyboardState()
        _ = state.handle(down(backspace))
        #expect(state.repeating == RepeatingKey(hidUsage: backspace, keysym: 0xFF08))
        _ = state.handle(down(right))
        #expect(state.repeating == RepeatingKey(hidUsage: right, keysym: 0xFF53))
    }

    @Test func modifiersAndCapsLockNeverRepeat() {
        var state = KeyboardState()
        for hid in [shift, command, capsLock, 0xE0, 0xE2, 0xE4, 0xE5, 0xE6, 0xE7] {
            _ = state.handle(down(hid))
            #expect(state.repeating == nil, "phím bổ trợ \(hid) không được lặp")
        }
    }

    @Test func holdingShiftThenALetterRepeatsTheLetterWithShiftStillHeld() {
        var state = KeyboardState()
        _ = state.handle(down(shift))
        _ = state.handle(down(a, "A", ignoring: "a", [.shift]))
        #expect(state.repeating == RepeatingKey(hidUsage: a, keysym: 0x41))
        _ = state.handle(up(a))
        #expect(state.repeating == nil)
        #expect(state.heldKeyCount == 1, "Shift vẫn đang giữ")
    }

    @Test func onlyTheLastPressedKeyRepeatsAndReleasingItDoesNotResumeTheEarlierOne() {
        var state = KeyboardState()
        _ = state.handle(down(a, "a"))
        _ = state.handle(down(b, "b"))
        #expect(state.repeating?.hidUsage == b)
        _ = state.handle(up(b))
        #expect(state.repeating == nil, "nhả b không làm a lặp lại")
    }

    @Test func releasingAnEarlierKeyDoesNotStopTheLaterOne() {
        var state = KeyboardState()
        _ = state.handle(down(a, "a"))
        _ = state.handle(down(b, "b"))
        _ = state.handle(up(a))
        #expect(state.repeating?.hidUsage == b)
    }

    @Test func ifTheSystemItselfRepeatsThePressWeStopRepeatingToAvoidDoubling() {
        var state = KeyboardState()
        _ = state.handle(down(a, "a"))
        #expect(state.repeating != nil)
        let again = state.handle(down(a, "a")) // lần lặp do iPadOS gửi
        #expect(again == [key(true, 0x61)], "vẫn chuyển tiếp lần lặp của hệ điều hành")
        #expect(state.repeating == nil, "đã có lặp từ hệ điều hành thì ngừng lặp thủ công")
    }

    @Test func releaseAllStopsRepeating() {
        var state = KeyboardState()
        _ = state.handle(down(a, "a"))
        _ = state.releaseAll()
        #expect(state.repeating == nil)
    }

    @Test func aKeyThatProducesNothingDoesNotStartRepeating() {
        var state = KeyboardState()
        _ = state.handle(down(0x01)) // HID 0x01 (lỗi rollover) không có keysym
        #expect(state.repeating == nil)
    }

    @Test func repeatTimingMatchesARealKeyboard() {
        #expect(KeyRepeat.initialDelay > .milliseconds(250), "đủ lâu để một cú gõ thường không bị lặp")
        #expect(KeyRepeat.initialDelay < .milliseconds(600))
        #expect(KeyRepeat.interval < .milliseconds(100))
    }
}

@Suite("KeysymMapper.commandChord")
struct CommandChordTests {
    @Test func buildsCommandDownKeyDownKeyUpCommandUp() {
        #expect(KeysymMapper.commandChord("f") == [key(true, 0xFFE7), key(true, 0x66), key(false, 0x66), key(false, 0xFFE7)])
    }

    @Test func uppercaseIsTreatedAsTheLowercaseKey() {
        // ⌘F là phím f giữ Command; chữ hoa sẽ thành keysym khác (0x46) và Mac hiểu là ⇧⌘F.
        #expect(KeysymMapper.commandChord("F") == KeysymMapper.commandChord("f"))
    }

    @Test func charactersWithoutAKeysymGiveNil() {
        #expect(KeysymMapper.commandChord("\u{7}") == nil)
    }
}

@Suite("Audit: ⌘ đang giữ và giới hạn lặp")
struct CommandHeldTests {
    @Test func commandChordSendsOnlyTheLetterWhenCommandIsAlreadyDown() {
        #expect(KeysymMapper.commandChord("f", commandAlreadyDown: true) == [key(true, 0x66), key(false, 0x66)])
        #expect(KeysymMapper.commandChord("f", commandAlreadyDown: false)?.count == 4)
    }

    @Test func stateReportsHeldKeysyms() {
        var state = KeyboardState()
        _ = state.handle(down(0xE3, "", [.command]))
        #expect(state.isHolding(keysym: KeysymMapper.commandLeft))
        _ = state.handle(up(0xE3))
        #expect(!state.isHolding(keysym: KeysymMapper.commandLeft))
    }

    @Test func repeatHasASafetyStop() {
        #expect(KeyRepeat.maximumDuration >= .seconds(10) && KeyRepeat.maximumDuration <= .seconds(60))
    }
}
