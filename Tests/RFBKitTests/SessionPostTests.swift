import Foundation
import Testing
@testable import RFBKit

/// Chờ tới khi `condition` đúng hoặc hết `timeout`. `post` ghi bất đồng bộ nên test phải chờ.
private func waitUntil(timeout: Duration = .seconds(3), _ condition: () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await condition()
}

@Suite("RFBSession.post: hàng đợi gửi có thứ tự")
struct SessionPostTests {
    @Test func messagesReachTheStreamInExactlyTheOrderTheyWerePosted() async throws {
        let (session, stream) = try makeSession([])
        var expected = Data()
        for index in 0..<200 {
            let x = UInt16(index)
            let messages: [ClientMessage] = [.pointerEvent(buttons: 1, x: x, y: 7), .pointerEvent(buttons: 0, x: x, y: 7)]
            session.post(messages) // nonisolated: không cần await
            expected.append(messages[0].wireBytes)
            expected.append(messages[1].wireBytes)
        }

        let arrived = await waitUntil { await stream.written.count == expected.count }
        let written = await stream.written
        #expect(arrived, "chỉ nhận được \(written.count) trên \(expected.count) byte")
        #expect(written == expected) // nhấn luôn trước nhả, theo đúng thứ tự gửi
    }

    @Test func emptyPostSendsNothing() async throws {
        let (session, stream) = try makeSession([])
        session.post([])
        session.post([.keyEvent(isDown: true, keysym: 0x61)])
        let arrived = await waitUntil { await stream.written.count == 8 }
        #expect(arrived)
        #expect(await stream.written == ClientMessage.keyEvent(isDown: true, keysym: 0x61).wireBytes)
    }

    @Test func nothingIsSentAfterClose() async throws {
        let (session, stream) = try makeSession([])
        await session.close()
        session.post([.keyEvent(isDown: true, keysym: 0x61)])
        try await Task.sleep(for: .milliseconds(100))
        #expect(await stream.written.isEmpty)
    }

    @Test func postAndSendShareOneStreamWithoutCorruptingMessages() async throws {
        let (session, stream) = try makeSession([])
        session.post([.pointerEvent(buttons: 0, x: 1, y: 2)])
        _ = await waitUntil { await stream.written.count == 6 }
        try await session.requestUpdate()
        let written = await stream.written
        #expect(written.count == 6 + 10)
        #expect(written.prefix(6) == ClientMessage.pointerEvent(buttons: 0, x: 1, y: 2).wireBytes)
    }
}
