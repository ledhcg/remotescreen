import Foundation
import Testing
@testable import RFBKit

@Suite("OutboundCoalescer: chỉ bỏ những lần di chuột thừa")
struct OutboundCoalescerTests {
    private func p(_ buttons: UInt8, _ x: UInt16) -> ClientMessage { .pointerEvent(buttons: buttons, x: x, y: 0) }

    @Test func aDragKeepsThePressPointTheLastMoveAndTheRelease() {
        var c = OutboundCoalescer()
        let out = c.coalesce([p(1, 10), p(1, 20), p(1, 30), p(1, 40), p(0, 40)])
        #expect(out == [p(1, 10), p(1, 40), p(0, 40)], "nhấn ở 10 phải giữ nguyên vị trí, chỉ bỏ các lần di ở giữa")
    }

    @Test func clicksAndDoubleClicksAreUntouched() {
        var c = OutboundCoalescer()
        let clicks = [p(0, 5), p(1, 5), p(0, 5), p(1, 5), p(0, 5)]
        #expect(c.coalesce(clicks) == clicks)
    }

    @Test func wheelTicksAreNeverMerged() {
        var c = OutboundCoalescer()
        let ticks = [p(0, 5), p(16, 5), p(0, 5), p(16, 5), p(0, 5), p(16, 5), p(0, 5)]
        #expect(c.coalesce(ticks) == ticks, "ba nấc cuộn phải còn đủ ba")
    }

    @Test func hoverMovesCollapseToTheLatest() {
        var c = OutboundCoalescer()
        #expect(c.coalesce([p(0, 1), p(0, 2), p(0, 3)]) == [p(0, 3)])
    }

    @Test func keysAndRequestsAreNeverDroppedOrReordered() {
        var c = OutboundCoalescer()
        let key = ClientMessage.keyEvent(isDown: true, keysym: 0x61)
        let request = ClientMessage.framebufferUpdateRequest(incremental: true, rect: PixelRect(x: 0, y: 0, width: 4, height: 4))
        let input = [p(0, 1), key, p(0, 2), request, p(0, 3), p(0, 4)]
        // Lần di trước một thông điệp khác loại không bị bỏ (không có lần di nào ngay sau nó để thay thế).
        #expect(c.coalesce(input) == [p(0, 1), key, p(0, 2), request, p(0, 4)])
    }

    /// Trạng thái nút phải mang qua các lần gộp: lần nhấn cuối của đợt trước khiến lần đầu đợt sau là "di khi đang giữ nút".
    @Test func buttonStateCarriesAcrossBatches() {
        var c = OutboundCoalescer()
        _ = c.coalesce([p(1, 10)])
        #expect(c.lastButtons == 1)
        #expect(c.coalesce([p(1, 20), p(1, 30), p(0, 30)]) == [p(1, 30), p(0, 30)])
    }
}
