import Testing
@testable import InputKit

@Suite("ModifierKeys: held, latched once, locked (Sidecar style)")
struct ModifierKeysTests {
    private let cmd = StickyModifier.command
    private func down(_ m: StickyModifier) -> InputIntent { .key(KeyStroke(keysym: m.keysym, macKeyCode: m.macKeyCode, isDown: true)) }
    private func up(_ m: StickyModifier) -> InputIntent { .key(KeyStroke(keysym: m.keysym, macKeyCode: m.macKeyCode, isDown: false)) }

    @Test func holdingPressesImmediatelySoCommandClickWorks() {
        var keys = ModifierKeys()
        #expect(keys.touchDown(cmd, at: 0) == [down(cmd)])
        #expect(keys.state(of: cmd) == .held)
        // Two clicks while held: ⌘ stays down.
        #expect(keys.actionCompleted().isEmpty)
        #expect(keys.actionCompleted().isEmpty)
        #expect(keys.touchUp(cmd, at: 2) == [up(cmd)], "finger lifted after use: release")
        #expect(keys.state(of: cmd) == .up)
    }

    @Test func aShortTapBecomesOneShotAndReleasesAfterTheNextAction() {
        var keys = ModifierKeys()
        _ = keys.touchDown(cmd, at: 0)
        #expect(keys.touchUp(cmd, at: 0.1).isEmpty)
        #expect(keys.state(of: cmd) == .oneShot)
        #expect(keys.actionCompleted() == [up(cmd)], "a finished key or click releases it")
        #expect(keys.state(of: cmd) == .up)
    }

    @Test func aDoubleTapLocksUntilTappedAgain() {
        var keys = ModifierKeys()
        _ = keys.tap(cmd, at: 0)
        #expect(keys.tap(cmd, at: 0.2).isEmpty, "second tap: lock, sends nothing (key stays down)")
        #expect(keys.state(of: cmd) == .locked)
        #expect(keys.actionCompleted().isEmpty, "locked does not release after an action")
        #expect(keys.tap(cmd, at: 5) == [up(cmd)], "tap while locked: unlock")
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
        #expect(keys.touchUp(cmd, at: 1.5) == [up(cmd)], "held long with nothing done: does not become latched")
    }

    @Test func releaseAllGoesInReversePressOrder() {
        var keys = ModifierKeys()
        _ = keys.touchDown(.control, at: 0)
        _ = keys.tap(.shift, at: 0)
        _ = keys.tap(cmd, at: 0); _ = keys.tap(cmd, at: 0.1) // lock ⌘
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
        func count(_ messages: [InputIntent]) {
            for case .key(let stroke) in messages { balance += stroke.isDown ? 1 : -1 }
        }
        count(keys.touchDown(cmd, at: 0)); count(keys.touchUp(cmd, at: 0.1)) // latch
        count(keys.touchDown(cmd, at: 0.2)); count(keys.touchUp(cmd, at: 0.25)) // lock
        count(keys.touchDown(.option, at: 1)); count(keys.actionCompleted()); count(keys.touchUp(.option, at: 2))
        count(keys.tap(cmd, at: 3)) // unlock
        count(keys.releaseAll())
        #expect(balance == 0, "every press must have exactly one release")
    }
}
