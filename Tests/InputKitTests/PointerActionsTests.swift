import RFBKit
import Testing
@testable import InputKit

@Suite("PointerActions: một thao tác chuột vừa xong")
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
        // Một nấc cuộn là nhấn rồi nhả nút 4 (bit 3): không phải cú nhấp, không được nhả ⌘ (⌘+cuộn là phóng trong nhiều app).
        #expect(!PointerActions.completesAButtonAction([pointer(8), pointer(0), pointer(16), pointer(0)], previousButtons: &state))
        #expect(!PointerActions.completesAButtonAction([pointer(0), pointer(0)], previousButtons: &state))
    }

    @Test func keyEventsAreIgnored() {
        var state: UInt8 = 1
        #expect(!PointerActions.completesAButtonAction([.keyEvent(isDown: true, keysym: 0x61)], previousButtons: &state))
        #expect(state == 1)
    }
}
