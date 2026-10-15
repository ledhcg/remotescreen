import Foundation
import Testing
@testable import RFBKit

/// Hình chữ nhật ZRLE: tiêu đề, độ dài 32-bit, rồi dữ liệu nén.
private func zrleRect(_ x: UInt16, _ y: UInt16, _ w: UInt16, _ h: UInt16, compressed: Data) -> [UInt8] {
    var data = Data(rectHeader(x, y, w, h, encoding: 16))
    data.appendBigEndian(UInt32(compressed.count))
    data.append(compressed)
    return Array(data)
}

@Suite("RFBSession: ZRLE")
struct SessionZRLETests {
    @Test func decodesZRLEAndKeepsTheZlibStreamAcrossUpdates() async throws {
        // Hai cập nhật riêng biệt nhưng cùng một luồng zlib do Python nén liên tục. Nếu phiên tạo luồng mới
        // cho mỗi cập nhật thì cập nhật thứ hai sẽ lỗi (không có tiêu đề zlib).
        let first = update(rectCount: 1, zrleRect(0, 0, 4, 2, compressed: Data(hex: ZlibVectors.zrleSolidRed4x2)))
        let second = update(rectCount: 1, zrleRect(0, 0, 4, 2, compressed: Data(hex: ZlibVectors.zrleSolidGreen4x2SameStream)))
        let (session, _) = try makeSession(first + second)

        #expect(try await session.nextEvent() == .framebufferUpdate(dirty: [PixelRect(x: 0, y: 0, width: 4, height: 2)]))
        var buffer = await session.framebuffer
        #expect((0..<8).allSatisfy { buffer.rgb(x: $0 % 4, y: $0 / 4)! == (255, 0, 0) })

        _ = try await session.nextEvent()
        buffer = await session.framebuffer
        #expect((0..<8).allSatisfy { buffer.rgb(x: $0 % 4, y: $0 / 4)! == (0, 255, 0) })
    }

    @Test func aSessionThatMissedTheFirstChunkCannotDecodeTheSecond() async throws {
        let message = update(rectCount: 1, zrleRect(0, 0, 4, 2, compressed: Data(hex: ZlibVectors.zrleSolidGreen4x2SameStream)))
        let (session, _) = try makeSession(message)
        await #expect(throws: RFBError.self) { try await session.nextEvent() }
    }

    @Test func recordsPayloadSizePerEncoding() async throws {
        let compressed = Data(hex: ZlibVectors.zrleSolidRed4x2)
        let raw = update(rectCount: 1, rectHeader(0, 0, 1, 1, encoding: 0) + bgra(1, 2, 3))
        let zrle = update(rectCount: 1, zrleRect(0, 0, 4, 2, compressed: compressed))
        let (session, _) = try makeSession(raw + zrle)

        _ = try await session.nextEvent()
        _ = try await session.nextEvent()

        let statistics = await session.statistics
        #expect(statistics.payloadBytes[.raw] == 4)
        #expect(statistics.payloadBytes[.zrle] == compressed.count + 4)
        #expect(statistics.updateCount == 2)
    }

    @Test func rectangleOutsideTheFramebufferIsRejectedBeforeReadingPayload() async throws {
        let message = update(rectCount: 1, rectHeader(3, 0, 4, 2, encoding: 16))
        let (session, _) = try makeSession(message)
        await #expect(throws: RFBError.self) { try await session.nextEvent() }
    }

    @Test func absurdCompressedLengthIsRejected() async throws {
        let message = update(rectCount: 1, rectHeader(0, 0, 4, 2, encoding: 16) + [0x7F, 0xFF, 0xFF, 0xFF])
        let (session, _) = try makeSession(message)
        await #expect(throws: RFBError.self) { try await session.nextEvent() }
    }
}

@Suite("RFBSession: Cursor")
struct SessionCursorTests {
    @Test func deliversCursorWithoutTouchingTheFramebuffer() async throws {
        // Cursor pseudo-rect: x,y là điểm nóng, w,h là cỡ hình. 2×2 pixel BGRA rồi mặt nạ 2 byte.
        let pixels: [UInt8] = [1, 2, 3, 0, 4, 5, 6, 0, 7, 8, 9, 0, 10, 11, 12, 0]
        let body = rectHeader(1, 1, 2, 2, encoding: -239) + pixels + [0b1000_0000, 0b0100_0000]
        let (session, _) = try makeSession(update(rectCount: 1, body))

        let event = try await session.nextEvent()

        guard case .framebufferUpdate(let dirty, let cursor) = event else {
            Issue.record("không phải framebufferUpdate: \(event)")
            return
        }
        #expect(dirty.isEmpty)
        #expect(cursor?.hotspotX == 1)
        #expect(cursor?.hotspotY == 1)
        #expect(cursor?.bgra == [1, 2, 3, 255, 0, 0, 0, 0, 0, 0, 0, 0, 10, 11, 12, 255])
        #expect(await session.framebuffer.rgb(x: 0, y: 0)! == (0, 0, 0))
    }

    @Test func zeroSizedCursorMeansHidden() async throws {
        let (session, _) = try makeSession(update(rectCount: 1, rectHeader(0, 0, 0, 0, encoding: -239)))
        guard case .framebufferUpdate(_, let cursor) = try await session.nextEvent() else {
            Issue.record("không phải framebufferUpdate")
            return
        }
        #expect(cursor?.isEmpty == true)
    }

    @Test func oversizedCursorIsRejected() async throws {
        let (session, _) = try makeSession(update(rectCount: 1, rectHeader(0, 0, 4000, 4000, encoding: -239)))
        await #expect(throws: RFBError.self) { try await session.nextEvent() }
    }
}
