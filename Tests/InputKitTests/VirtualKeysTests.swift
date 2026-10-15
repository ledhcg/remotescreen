import Foundation
import RFBKit
import Testing
@testable import InputKit

private func key(_ isDown: Bool, _ keysym: UInt32) -> ClientMessage { .keyEvent(isDown: isDown, keysym: keysym) }

/// Giá trị kỳ vọng lấy từ `keysymdef.h` của X11, không sinh từ chính code đang test.
@Suite("VirtualKey")
struct VirtualKeyTests {
    @Test(arguments: [
        (VirtualKey.escape, UInt32(0xFF1B)), (.tab, 0xFF09), (.left, 0xFF51), (.up, 0xFF52), (.right, 0xFF53), (.down, 0xFF54),
        (.home, 0xFF50), (.end, 0xFF57), (.pageUp, 0xFF55), (.pageDown, 0xFF56), (.forwardDelete, 0xFFFF),
    ])
    func keysyms(key: VirtualKey, keysym: UInt32) {
        #expect(key.keysym == keysym)
    }

    @Test func tapIsPressThenRelease() {
        #expect(VirtualKey.escape.tap == [key(true, 0xFF1B), key(false, 0xFF1B)])
    }

    @Test func everyKeyHasADistinctKeysym() {
        #expect(Set(VirtualKey.allCases.map(\.keysym)).count == VirtualKey.allCases.count)
    }

    @Test func modifierKeysymsMatchTheHardwareKeyboardMapping() {
        // Cùng bảng với `KeysymMapper.specialKeys` của bàn phím cứng, để hai đường nhập không lệch nhau.
        #expect(StickyModifier.control.keysym == KeysymMapper.keysym(for: KeyPress(hidUsage: 0xE0, isDown: true)))
        #expect(StickyModifier.shift.keysym == KeysymMapper.keysym(for: KeyPress(hidUsage: 0xE1, isDown: true)))
        #expect(StickyModifier.option.keysym == KeysymMapper.keysym(for: KeyPress(hidUsage: 0xE2, isDown: true)))
        #expect(StickyModifier.command.keysym == KeysymMapper.keysym(for: KeyPress(hidUsage: 0xE3, isDown: true)))
    }
}

@Suite("ModifierKeys qua thanh phím phụ (chạm)")
struct KeyBarModifierTests {
    @Test func aTapLatchesAndALateSecondTapCancels() {
        var keys = ModifierKeys()
        #expect(keys.tap(.command, at: 0) == [key(true, KeysymMapper.commandLeft)])
        #expect(keys.state(of: .command) == .oneShot)
        #expect(keys.tap(.command, at: 1) == [key(false, KeysymMapper.commandLeft)])
        #expect(keys.state(of: .command) == .up)
    }

    @Test func modifiersAreIndependent() {
        var keys = ModifierKeys()
        _ = keys.tap(.control, at: 0)
        _ = keys.tap(.option, at: 1)
        _ = keys.tap(.control, at: 2) // bỏ Control, Option vẫn dính
        #expect(keys.active == [.option])
    }

    /// Chuỗi đầy đủ của Cmd+C: Command xuống, `c` xuống rồi lên, Command lên.
    @Test func commandCSequenceIsCorrectlyOrdered() {
        var keys = ModifierKeys()
        var sent = keys.tap(.command, at: 0)
        sent += KeyboardState.typing("c")
        sent += keys.actionCompleted()
        #expect(sent == [
            key(true, KeysymMapper.commandLeft), key(true, 0x63), key(false, 0x63), key(false, KeysymMapper.commandLeft),
        ])
        #expect(keys.actionCompleted().isEmpty, "nhả lần hai không gửi gì, tránh nhả thừa")
    }

    /// Chạm nhiều lần (thưa) cùng phím không được để Mac thấy hai lần nhấn xuống liên tiếp.
    @Test func neverSendsTwoDownsOrTwoUpsInARow() {
        var keys = ModifierKeys()
        var sent: [ClientMessage] = []
        for second in 0..<5 { sent += keys.tap(.control, at: Double(second)) }
        sent += keys.releaseAll()
        #expect(sent == [key(true, 0xFFE3), key(false, 0xFFE3), key(true, 0xFFE3), key(false, 0xFFE3), key(true, 0xFFE3), key(false, 0xFFE3)])
    }
}
