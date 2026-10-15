import Foundation
import Testing
@testable import RFBKit

/// Expected bytes written by hand following RFC 6143 section 7.5, not generated from the code under test.
@Suite("ClientMessage")
struct ClientMessageTests {
    @Test func setPixelFormat() {
        let expected: [UInt8] = [0, 0, 0, 0, 32, 24, 0, 1, 0, 255, 0, 255, 0, 255, 16, 8, 0, 0, 0, 0]
        #expect(ClientMessage.setPixelFormat(.bgra8888).wireBytes == Data(expected))
    }

    @Test func setEncodingsEncodesNegativeValuesAsTwosComplement() {
        let message = ClientMessage.setEncodings([.raw, .copyRect, .zrle, .cursor])
        // 2 (type), 0 (padding), count = 4, then four 32-bit numbers. -239 = 0xFFFFFF11.
        let expected: [UInt8] = [2, 0, 0, 4, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 16, 0xFF, 0xFF, 0xFF, 0x11]
        #expect(message.wireBytes == Data(expected))
    }

    @Test func emptyEncodingList() {
        #expect(ClientMessage.setEncodings([]).wireBytes == Data([2, 0, 0, 0]))
    }

    @Test func framebufferUpdateRequest() {
        let rect = PixelRect(x: 10, y: 20, width: 300, height: 400)
        let incremental = ClientMessage.framebufferUpdateRequest(incremental: true, rect: rect)
        #expect(incremental.wireBytes == Data([3, 1, 0, 10, 0, 20, 0x01, 0x2C, 0x01, 0x90]))
        let full = ClientMessage.framebufferUpdateRequest(incremental: false, rect: rect)
        #expect(full.wireBytes.prefix(2) == Data([3, 0]))
    }

    @Test func keyEvent() {
        // Return = keysym 0xFF0D
        #expect(ClientMessage.keyEvent(isDown: true, keysym: 0xFF0D).wireBytes == Data([4, 1, 0, 0, 0, 0, 0xFF, 0x0D]))
        #expect(ClientMessage.keyEvent(isDown: false, keysym: 0x61).wireBytes == Data([4, 0, 0, 0, 0, 0, 0, 0x61]))
    }

    @Test func pointerEvent() {
        #expect(ClientMessage.pointerEvent(buttons: 1, x: 258, y: 3).wireBytes == Data([5, 1, 1, 2, 0, 3]))
    }

    @Test func clientCutTextUsesLatin1() {
        #expect(ClientMessage.clientCutText("héllo").wireBytes == Data([6, 0, 0, 0, 0, 0, 0, 5, 0x68, 0xE9, 0x6C, 0x6C, 0x6F]))
    }

    @Test func clientCutTextReplacesCharactersOutsideLatin1() {
        let wire = ClientMessage.clientCutText("a€").wireBytes
        #expect(wire.count == 8 + 2)
        #expect(wire.suffix(2) == Data([0x61, 0x3F])) // '€' → '?'
    }
}
