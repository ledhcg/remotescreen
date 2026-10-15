import Foundation
import Testing
@testable import RFBKit

/// Byte của message 23 đối chiếu với bố cục đọc từ `screensharingd` và `ScreensharingAgent` (protocol-notes 4h), không sinh từ
/// chính code đang test.
@Suite("Message 23 của Apple (cuộn mượt, chụm, xoay)")
struct AppleEventTests {
    private func u16(_ data: Data, _ offset: Int) -> UInt16 {
        data.dropFirst(offset).prefix(2).reduce(0) { $0 << 8 | UInt16($1) }
    }

    private func u32(_ data: Data, _ offset: Int) -> UInt32 {
        data.dropFirst(offset).prefix(4).reduce(0) { $0 << 8 | UInt32($1) }
    }

    @Test func scrollIsFiftyFourBytesWithTheAgentsFieldOffsets() {
        let message = ClientMessage.appleEvent(.scroll(AppleScroll(
            deltaX: -25, deltaY: 37, phase: .changed, momentum: .none, x: 300, y: 400
        )))
        let bytes = message.wireBytes
        #expect(Array(bytes.prefix(4)) == [23, 0, 0, 54], "loại 23, cờ 0, payload 54 byte (cỡ tối thiểu của loại 11)")
        let payload = Data(bytes.dropFirst(4))
        #expect(payload.count == 54)
        #expect(u16(payload, 0) == 1 && u16(payload, 2) == 11)
        #expect(Int16(bitPattern: u16(payload, 4)) == -2, "trục 2 (ngang), dòng = point / 10")
        #expect(Int16(bitPattern: u16(payload, 6)) == 3, "trục 1 (dọc)")
        #expect(Int32(bitPattern: u32(payload, 14)) == 37 * 65_536 / 10, "FixedPtDeltaAxis1 ở offset 14")
        #expect(Int32(bitPattern: u32(payload, 22)) == -25, "PointDeltaAxis2 ở offset 22")
        #expect(Int32(bitPattern: u32(payload, 26)) == 37, "PointDeltaAxis1 ở offset 26")
        #expect(u32(payload, 34) == 2, "ScrollPhase = changed")
        #expect(u32(payload, 38) == 0, "MomentumPhase")
        #expect(u32(payload, 46) == 2, "cờ: IsContinuous")
        #expect(u16(payload, 50) == 300 && u16(payload, 52) == 400)
    }

    @Test func momentumPhaseGoesToItsOwnField() {
        let payload = Data(ClientMessage.appleEvent(.scroll(AppleScroll(
            deltaX: 0, deltaY: 5, phase: .none, momentum: .continue, x: 0, y: 0
        ))).wireBytes.dropFirst(4))
        #expect(u32(payload, 34) == 0 && u32(payload, 38) == 2)
    }

    @Test func magnifyIsAVersionTwoPayloadWithADoubleALocationAndAPhase() {
        let bytes = ClientMessage.appleEvent(.magnify(0.25, phase: .changed, x: 10, y: 20)).wireBytes
        #expect(Array(bytes.prefix(4)) == [23, 0, 0, 32], "loại 3 bản 2: 32 byte (bản 1 bị Mac bỏ qua)")
        let payload = Data(bytes.dropFirst(4))
        #expect(u16(payload, 0) == 2 && u16(payload, 2) == 3)
        #expect(Array(payload[4..<12]) == [0x3F, 0xD0, 0, 0, 0, 0, 0, 0], "0,25 dạng double big-endian")
        #expect(u16(payload, 12) == 10 && u16(payload, 14) == 20)
        #expect(Array(payload[16..<24]) == [0, 0, 0, 0, 0, 0, 0, 2], "pha changed = 2, u64")
        #expect(Array(payload[24..<32]) == Array(repeating: 0, count: 8), "mask 0")
    }

    @Test func rotateIsKindFiveAndPhasesUseScrollPhaseValues() {
        let payload = Data(ClientMessage.appleEvent(.rotate(-15, phase: .began, x: 1, y: 2)).wireBytes.dropFirst(4))
        #expect(payload.count == 32 && u16(payload, 0) == 2 && u16(payload, 2) == 5)
        #expect(Double(bitPattern: payload[4..<12].reduce(0) { $0 << 8 | UInt64($1) }) == -15)
        #expect(payload[23] == 1)
        let ended = Data(ClientMessage.appleEvent(.rotate(0, phase: .ended, x: 1, y: 2)).wireBytes.dropFirst(4))
        #expect(ended[23] == 4)
    }

    @Test func hugeOrInvalidValuesNeverBreakTheFrame() {
        let scroll = ClientMessage.appleEvent(.scroll(AppleScroll(deltaX: .max, deltaY: .min, phase: .changed, x: 0, y: 0)))
        #expect(scroll.wireBytes.count == 58)
        #expect(ClientMessage.appleEvent(.magnify(.nan, phase: .changed, x: 0, y: 0)).wireBytes.count == 36)
    }
}
