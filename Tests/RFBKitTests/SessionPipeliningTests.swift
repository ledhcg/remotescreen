import Foundation
import Testing
@testable import RFBKit

/// Requests the next update as soon as the header of the current update arrives, so the server prepares the next frame in parallel with our receiving and decoding of
/// the previous one. Measured on a real 2560x1440 stream: without early requests each frame has to wait serially (one network round trip + decode).
@Suite("RFBSession: early update requests")
struct SessionPipeliningTests {
    private func pipelined(_ incoming: [UInt8], width: UInt16 = 4, height: UInt16 = 2) throws -> (RFBSession, ScriptedByteStream) {
        let stream = ScriptedByteStream(incoming)
        let info = ServerInit(width: width, height: height, pixelFormat: .bgra8888, name: "test")
        return (try RFBSession(stream: stream, serverInfo: info, pipelinesUpdateRequests: true), stream)
    }

    private func request(_ width: UInt16, _ height: UInt16) -> Data {
        Data([3, 1, 0, 0, 0, 0, UInt8(width >> 8), UInt8(width & 0xFF), UInt8(height >> 8), UInt8(height & 0xFF)])
    }

    /// Waits for the send queue (a separate task) to finish writing; returns what was written.
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
        try await Task.sleep(for: .milliseconds(100)) // if there is a surplus request, give it time to show up
        #expect(await stream.written == request(4, 2) + request(4, 2), "exactly two requests for two updates, no more")
        #expect(data.count >= 20)
    }

    /// Evidence that it requests **before** decoding: the update is truncated right after the header, decoding fails, but the request has already gone out.
    @Test func requestIsSentBeforeTheRectanglesAreRead() async throws {
        let (session, stream) = try pipelined(update(rectCount: 1, [])) // header only, no rectangles at all
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
        let (session, stream) = try pipelined([2, 2]) // two bells
        _ = try await session.nextEvent()
        _ = try await session.nextEvent()
        try await Task.sleep(for: .milliseconds(150))
        #expect(await stream.written.isEmpty, "the pending request is still in effect, asking for more would pile up requests")
    }

    /// The request sent at the start of an update used the old size. If the server resizes mid-way, it must re-request with the new size.
    @Test func resizeDuringAnUpdateIsFollowedByARequestWithTheNewSize() async throws {
        let (session, stream) = try pipelined(update(rectCount: 1, rectHeader(0, 0, 8, 6, encoding: -223)))
        _ = try await session.nextEvent()
        // The request after a resize is NOT incremental (second byte 0): Apple's server sends only DesktopSize and then waits.
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

@Suite("RFBSession: frame cadence")
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
        #expect(await stream.written.count == 30, "three updates, three requests, no delay")
    }

    /// The limit is a rate cap: three consecutive updates with a 200 ms spacing mean the third request goes out only after at least 400 ms.
    @Test func aLimitSpacesOutTheRequests() async throws {
        let (session, stream) = try pipelined(oneRect() + oneRect() + oneRect())
        await session.setMinimumUpdateInterval(.milliseconds(200))
        let started = ContinuousClock.now
        for _ in 0..<3 { _ = try await session.nextEvent() }

        // The first request goes out right after the third update (immediately); the next two are still deferred.
        #expect(await stream.written.count <= 20, "the third request must not go out earlier than the spacing")
        let deadline = ContinuousClock.now + .seconds(3)
        while await stream.written.count < 30, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        let elapsed = ContinuousClock.now - started
        #expect(await stream.written.count == 30)
        #expect(elapsed >= .milliseconds(380), "three requests 200 ms apart must take ≥ 400 ms, measured \(elapsed)")
    }

    @Test func theLimitCanBeLiftedMidSession() async throws {
        let (session, stream) = try pipelined(oneRect() + oneRect())
        await session.setMinimumUpdateInterval(.seconds(30)) // a very long spacing
        _ = try await session.nextEvent() // first request: there is no previous request, so it goes out immediately
        await session.setMinimumUpdateInterval(nil)
        _ = try await session.nextEvent()
        try await Task.sleep(for: .milliseconds(100))
        #expect(await stream.written.count == 20, "removing the limit makes the next request go out immediately, not wait 30 seconds")
    }
}
