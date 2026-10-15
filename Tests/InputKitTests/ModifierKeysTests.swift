import RFBKit
import Testing
@testable import InputKit

@Suite("ModifierKeys: giữ, dính một lần, khóa (kiểu Sidecar)")
struct ModifierKeysTests {
    private let cmd = StickyModifier.command
    private func down(_ m: StickyModifier) -> ClientMessage { .keyEvent(isDown: true, keysym: m.keysym) }
    private func up(_ m: StickyModifier) -> ClientMessage { .keyEvent(isDown: false, keysym: m.keysym) }

    @Test func holdingPressesImmediatelySoCommandClickWorks() {
        var keys = ModifierKeys()
        #expect(keys.touchDown(cmd, at: 0) == [down(cmd)])
        #expect(keys.state(of: cmd) == .held)
        // Hai cú nhấp trong lúc giữ: ⌘ vẫn nhấn.
        #expect(keys.actionCompleted().isEmpty)
        #expect(keys.actionCompleted().isEmpty)
        #expect(keys.touchUp(cmd, at: 2) == [up(cmd)], "nhấc ngón sau khi đã dùng: nhả")
        #expect(keys.state(of: cmd) == .up)
    }

    @Test func aShortTapBecomesOneShotAndReleasesAfterTheNextAction() {
        var keys = ModifierKeys()
        _ = keys.touchDown(cmd, at: 0)
        #expect(keys.touchUp(cmd, at: 0.1).isEmpty)
        #expect(keys.state(of: cmd) == .oneShot)
        #expect(keys.actionCompleted() == [up(cmd)], "một phím hay cú nhấp xong thì nhả")
        #expect(keys.state(of: cmd) == .up)
    }

    @Test func aDoubleTapLocksUntilTappedAgain() {
        var keys = ModifierKeys()
        _ = keys.tap(cmd, at: 0)
        #expect(keys.tap(cmd, at: 0.2).isEmpty, "chạm lần hai: khóa, không gửi gì (phím vẫn nhấn)")
        #expect(keys.state(of: cmd) == .locked)
        #expect(keys.actionCompleted().isEmpty, "khóa thì không nhả sau thao tác")
        #expect(keys.tap(cmd, at: 5) == [up(cmd)], "chạm khi đang khóa: mở khóa")
        #expect(keys.state(of: cmd) == .up)
    }

    @Test func aLateSecondTapCancelsTheOneShot() {
        var keys = ModifierKeys()
        _ = keys.tap(cmd, at: 0)
        #expect(keys.tap(cmd, at: 1.0) == [up(cmd)])
        #expect(keys.state(of: cmd) == .up)
    }

    @Test func aLongHoldWithoutAnyActionJustReleases() {
        var keys = ModifierKeys()
        _ = keys.touchDown(cmd, at: 0)
        #expect(keys.touchUp(cmd, at: 1.5) == [up(cmd)], "giữ lâu mà không làm gì: không biến thành dính")
    }

    @Test func releaseAllGoesInReversePressOrder() {
        var keys = ModifierKeys()
        _ = keys.touchDown(.control, at: 0)
        _ = keys.tap(.shift, at: 0)
        _ = keys.tap(cmd, at: 0); _ = keys.tap(cmd, at: 0.1) // khóa ⌘
        #expect(keys.active == [.control, .shift, cmd])
        #expect(keys.releaseAll() == [up(cmd), up(.shift), up(.control)])
        #expect(keys.active.isEmpty)
    }

    @Test func oneShotModifiersReleaseInReverseOrderAfterAnAction() {
        var keys = ModifierKeys()
        _ = keys.tap(.shift, at: 0)
        _ = keys.tap(cmd, at: 1)
        #expect(keys.actionCompleted() == [up(cmd), up(.shift)])
    }

    @Test func everyPressHasExactlyOneRelease() {
        var keys = ModifierKeys()
        var balance = 0
        func count(_ messages: [ClientMessage]) {
            for case .keyEvent(let isDown, _) in messages { balance += isDown ? 1 : -1 }
        }
        count(keys.touchDown(cmd, at: 0)); count(keys.touchUp(cmd, at: 0.1)) // dính
        count(keys.touchDown(cmd, at: 0.2)); count(keys.touchUp(cmd, at: 0.25)) // khóa
        count(keys.touchDown(.option, at: 1)); count(keys.actionCompleted()); count(keys.touchUp(.option, at: 2))
        count(keys.tap(cmd, at: 3)) // mở khóa
        count(keys.releaseAll())
        #expect(balance == 0, "mỗi lần nhấn phải có đúng một lần nhả")
    }
}
