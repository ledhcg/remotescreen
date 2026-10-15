import RFBKit
import Testing
@testable import InputKit

@Suite("PointerActions: a mouse action has just finished")
struct PointerActionsTests {
    private func pointer(_ buttons: UInt8) -> ClientMessage { .pointerEvent(buttons: buttons, x: 10, y: 10) }

    @Test func aClickInOneBatchCompletes() {
        var state: UInt8 = 0
        #expect(PointerActions.completesAButtonAction([pointer(0), pointer(1), pointer(0)], previousButtons: &state))
        #expect(state == 0)
    }

    @Test func aDragSpanningBatchesCompletesOnlyWhenReleased() {
        var state: UInt8 = 0
        #expect(!PointerActions.completesAButtonAction([pointer(1)], previousButtons: &state))
        #expect(!PointerActions.completesAButtonAction([pointer(1), pointer(1)], previousButtons: &state))
        #expect(PointerActions.completesAButtonAction([pointer(0)], previousButtons: &state))
    }

    @Test func rightClickCounts() {
        var state: UInt8 = 0
        #expect(PointerActions.completesAButtonAction([pointer(4), pointer(0)], previousButtons: &state))
    }

    @Test func wheelTicksAndMovesDoNot() {
        var state: UInt8 = 0
        // One scroll tick is press then release of button 4 (bit 3): not a click, must not release ⌘ (⌘+scroll is zoom in many apps).
        #expect(!PointerActions.completesAButtonAction([pointer(8), pointer(0), pointer(16), pointer(0)], previousButtons: &state))
        #expect(!PointerActions.completesAButtonAction([pointer(0), pointer(0)], previousButtons: &state))
    }

    @Test func keyEventsAreIgnored() {
        var state: UInt8 = 1
        #expect(!PointerActions.completesAButtonAction([.keyEvent(isDown: true, keysym: 0x61)], previousButtons: &state))
        #expect(state == 1)
    }
}
