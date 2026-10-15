import Foundation
import Testing
@testable import RFBKit

/// Xin cập nhật kế tiếp ngay khi nhận tiêu đề của cập nhật hiện tại, để server làm khung sau song song với việc ta nhận và giải mã
/// khung trước. Đo trên luồng thật 2560x1440: không xin sớm thì mỗi khung phải chờ nối đuôi (một vòng mạng + giải mã).
@Suite("RFBSession: xin cập nhật sớm")
struct SessionPipeliningTests {
    private func pipelined(_ incoming: [UInt8], width: UInt16 = 4, height: UInt16 = 2) throws -> (RFBSession, ScriptedByteStream) {
        let stream = ScriptedByteStream(incoming)
        let info = ServerInit(width: width, height: height, pixelFormat: .bgra8888, name: "test")
        return (try RFBSession(stream: stream, serverInfo: info, pipelinesUpdateRequests: true), stream)
    }

    private func request(_ width: UInt16, _ height: UInt16) -> Data {
        Data([3, 1, 0, 0, 0, 0, UInt8(width >> 8), UInt8(width & 0xFF), UInt8(height >> 8), UInt8(height & 0xFF)])
    }

    /// Đợi hàng đợi gửi (một task riêng) ghi xong; trả về những gì đã ghi.
    private func written(_ stream: ScriptedByteStream, atLeast count: Int) async -> Data {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            let data = await stream.written
            if data.count >= count { return data }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return await stream.written
    }

    @Test func requestsTheNextUpdateOncePerUpdate() async throws {
        let one = rectHeader(0, 0, 1, 1, encoding: 0) + bgra(1, 2, 3)
        let (session, stream) = try pipelined(update(rectCount: 1, one) + update(rectCount: 1, one))
        _ = try await session.nextEvent()
        _ = try await session.nextEvent()
        let data = await written(stream, atLeast: 20)
        try await Task.sleep(for: .milliseconds(100)) // nếu có yêu cầu thừa, cho nó thời gian để lộ ra
        #expect(await stream.written == request(4, 2) + request(4, 2), "đúng hai yêu cầu cho hai cập nhật, không hơn")
        #expect(data.count >= 20)
    }

    /// Bằng chứng nó xin **trước khi** giải mã: cập nhật bị cắt cụt ngay sau tiêu đề, giải mã thất bại, nhưng yêu cầu đã đi.
    @Test func requestIsSentBeforeTheRectanglesAreRead() async throws {
        let (session, stream) = try pipelined(update(rectCount: 1, [])) // chỉ có tiêu đề, không có hình chữ nhật nào
        await #expect(throws: RFBError.self) { _ = try await session.nextEvent() }
        #expect(await written(stream, atLeast: 10) == request(4, 2))
    }

    @Test func aSessionThatDoesNotPipelineNeverRequestsByItself() async throws {
        let one = rectHeader(0, 0, 1, 1, encoding: 0) + bgra(1, 2, 3)
        let (session, stream) = try makeSession(update(rectCount: 1, one))
        _ = try await session.nextEvent()
        try await Task.sleep(for: .milliseconds(150))
        #expect(await stream.written.isEmpty)
    }

    @Test func messagesThatAreNotUpdatesDoNotRequestAnything() async throws {
        let (session, stream) = try pipelined([2, 2]) // hai tiếng chuông
        _ = try await session.nextEvent()
        _ = try await session.nextEvent()
        try await Task.sleep(for: .milliseconds(150))
        #expect(await stream.written.isEmpty, "yêu cầu đang chờ vẫn còn hiệu lực, xin thêm sẽ chất đống yêu cầu")
    }

    /// Yêu cầu đã gửi ở đầu cập nhật dùng cỡ cũ. Server đổi cỡ giữa chừng thì phải xin lại bằng cỡ mới.
    @Test func resizeDuringAnUpdateIsFollowedByARequestWithTheNewSize() async throws {
        let (session, stream) = try pipelined(update(rectCount: 1, rectHeader(0, 0, 8, 6, encoding: -223)))
        _ = try await session.nextEvent()
        // Yêu cầu sau khi đổi cỡ là KHÔNG tăng dần (byte thứ hai 0): server Apple chỉ gửi DesktopSize rồi chờ.
        var full = request(8, 6)
        full[1] = 0
        #expect(await written(stream, atLeast: 20) == request(4, 2) + full)
    }

    @Test func decodeTimeIsAccountedForPixelWork() async throws {
        let side = 512
        let pixels = [UInt8](repeating: 7, count: side * side * 4)
        let (session, _) = try pipelined(
            update(rectCount: 1, rectHeader(0, 0, UInt16(side), UInt16(side), encoding: 0) + pixels), width: UInt16(side), height: UInt16(side)
        )
        _ = try await session.nextEvent()
        #expect(await session.statistics.decodeTime > .zero)
    }
}

@Suite("RFBSession: nhịp khung hình")
struct SessionPacingTests {
    private func oneRect() -> [UInt8] { update(rectCount: 1, rectHeader(0, 0, 1, 1, encoding: 0) + bgra(1, 2, 3)) }

    private func pipelined(_ incoming: [UInt8]) throws -> (RFBSession, ScriptedByteStream) {
        let stream = ScriptedByteStream(incoming)
        let info = ServerInit(width: 4, height: 2, pixelFormat: .bgra8888, name: "test")
        return (try RFBSession(stream: stream, serverInfo: info, pipelinesUpdateRequests: true), stream)
    }

    @Test func withoutALimitRequestsGoOutImmediately() async throws {
        let (session, stream) = try pipelined(oneRect() + oneRect() + oneRect())
        for _ in 0..<3 { _ = try await session.nextEvent() }
        try await Task.sleep(for: .milliseconds(50))
        #expect(await stream.written.count == 30, "ba cập nhật, ba yêu cầu, không chậm trễ")
    }

    /// Giới hạn là trần tốc độ: ba cập nhật liên tiếp với giãn cách 200 ms thì yêu cầu thứ ba chỉ đi sau ít nhất 400 ms.
    @Test func aLimitSpacesOutTheRequests() async throws {
        let (session, stream) = try pipelined(oneRect() + oneRect() + oneRect())
        await session.setMinimumUpdateInterval(.milliseconds(200))
        let started = ContinuousClock.now
        for _ in 0..<3 { _ = try await session.nextEvent() }

        // Ngay sau cập nhật thứ ba mới có yêu cầu đầu (đi ngay); hai yêu cầu sau còn bị hoãn.
        #expect(await stream.written.count <= 20, "yêu cầu thứ ba không được đi sớm hơn giãn cách")
        let deadline = ContinuousClock.now + .seconds(3)
        while await stream.written.count < 30, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        let elapsed = ContinuousClock.now - started
        #expect(await stream.written.count == 30)
        #expect(elapsed >= .milliseconds(380), "ba yêu cầu cách nhau 200 ms phải mất ≥ 400 ms, đo được \(elapsed)")
    }

    @Test func theLimitCanBeLiftedMidSession() async throws {
        let (session, stream) = try pipelined(oneRect() + oneRect())
        await session.setMinimumUpdateInterval(.seconds(30)) // một giãn cách rất dài
        _ = try await session.nextEvent() // yêu cầu đầu: chưa có yêu cầu trước nên đi ngay
        await session.setMinimumUpdateInterval(nil)
        _ = try await session.nextEvent()
        try await Task.sleep(for: .milliseconds(100))
        #expect(await stream.written.count == 20, "gỡ giới hạn thì yêu cầu kế tiếp đi ngay, không chờ 30 giây")
    }
}
