import Foundation
import Network
import Testing
@testable import RFBKit

/// Bugs found during the project audit, each test keeps one bug from coming back.
@Suite("Audit: protocol and safety")
struct AuditFixTests {
    private func session(_ incoming: [UInt8], format: PixelFormat = .bgra8888, width: UInt16 = 4, height: UInt16 = 2,
                         pipelined: Bool = false) throws -> (RFBSession, ScriptedByteStream) {
        let stream = ScriptedByteStream(incoming)
        let info = ServerInit(width: width, height: height, pixelFormat: .bgra8888, name: "t")
        return (try RFBSession(stream: stream, serverInfo: info, pipelinesUpdateRequests: pipelined, pixelFormat: format), stream)
    }

    // MARK: Cursor at 16 bit

    /// It used to always read 4 bytes per pixel: a 2x2 cursor at 16 bit shifted the stream and turned the bell after it into garbage.
    @Test func cursorPixelsFollowTheClientPixelFormatIn16Bit() async throws {
        let pixels: [UInt8] = [0x00, 0xF8, 0x00, 0xF8, 0x1F, 0x00, 0x1F, 0x00] // red, red, blue, blue (RGB565 LE)
        let mask: [UInt8] = [0b1100_0000, 0b1100_0000]
        let body = rectHeader(1, 1, 2, 2, encoding: -239) + pixels + mask
        let (s, _) = try session(update(rectCount: 1, body) + [2], format: .rgb565)
        guard case .framebufferUpdate(_, let cursor?) = try await s.nextEvent() else {
            Issue.record("did not receive the cursor image"); return
        }
        #expect(cursor.width == 2 && cursor.height == 2)
        #expect(try await s.nextEvent() == .bell, "the stream must still be aligned after the cursor")
    }

    // MARK: Oversized clipboard

    @Test func oversizedServerCutTextIsSkippedWithoutDroppingTheSession() async throws {
        let length = RFBSession.maxCutTextLength + 10
        var incoming: [UInt8] = [3, 0, 0, 0]
        incoming += withUnsafeBytes(of: UInt32(length).bigEndian) { Array($0) }
        incoming += [UInt8](repeating: 0x41, count: length)
        incoming += [2] // bell right after
        let (s, _) = try session(incoming)
        #expect(try await s.nextEvent() == .clipboardSkipped(bytes: length))
        #expect(try await s.nextEvent() == .bell)
    }

    @Test func oversizedAppleClipboardIsSkippedWithoutInflating() async throws {
        let compressed = 1000
        var incoming: [UInt8] = [31, 0, 0, 0]
        incoming += withUnsafeBytes(of: UInt32(7).bigEndian) { Array($0) }                     // token
        incoming += withUnsafeBytes(of: UInt32(ClipboardTransfer.maxUncompressed + 1).bigEndian) { Array($0) }
        incoming += withUnsafeBytes(of: UInt32(compressed).bigEndian) { Array($0) }
        incoming += [UInt8](repeating: 0xEE, count: compressed)                                // not valid zlib: must not be decompressed
        incoming += [2]
        let (s, _) = try session(incoming)
        #expect(try await s.nextEvent() == .clipboardSkipped(bytes: ClipboardTransfer.maxUncompressed + 1))
        #expect(try await s.nextEvent() == .bell)
    }

    // MARK: Memory cap

    @Test func hugeFramebuffersAreRefusedButAn8KScreenIsFine() throws {
        #expect(throws: RFBError.self) { _ = try Framebuffer(width: 16_384, height: 16_384) }
        _ = try Framebuffer(width: 7680, height: 4320) // 8K
    }

    // MARK: CopyRect

    /// Cross-checked against the obvious approach (capture the source region first, then write) over many overlap patterns.
    @Test(arguments: [(0, 0, 2, 1), (2, 1, 0, 0), (1, 0, 0, 0), (0, 0, 1, 0), (0, 1, 0, 0), (0, 0, 0, 1), (1, 1, 1, 0)])
    func copyRectMatchesASnapshotCopyForAnyOverlap(sx: Int, sy: Int, dx: Int, dy: Int) throws {
        let width = 5, height = 4
        var buffer = try Framebuffer(width: width, height: height)
        // A loop instead of flatMap: the Swift 6.1 compiler cannot type-check the combined expression.
        var pattern: [UInt8] = []
        for i in 0..<(width * height) {
            pattern.append(UInt8(truncatingIfNeeded: i))
            pattern.append(UInt8(truncatingIfNeeded: i * 3))
            pattern.append(UInt8(truncatingIfNeeded: i * 7))
            pattern.append(0)
        }
        try buffer.write(buffer.bounds, bgra: pattern)
        let source = PixelRect(x: sx, y: sy, width: 3, height: 3)
        var expected = pattern
        for row in 0..<3 { for col in 0..<3 { for c in 0..<4 {
            expected[((dy + row) * width + dx + col) * 4 + c] = pattern[((sy + row) * width + sx + col) * 4 + c]
        } } }
        try buffer.copy(from: source, toX: dx, y: dy)
        #expect(buffer.pixels == expected)
    }

    // MARK: RFB 3.3

    @Test func rfb33DoesNotSendASecurityTypeByte() async throws {
        let stream = ScriptedByteStream([])
        try await Handshake.selectSecurityType(.vncAuthentication, version: .v3_3, over: stream)
        #expect(await stream.written.isEmpty)
        try await Handshake.selectSecurityType(.vncAuthentication, version: .v3_8, over: stream)
        #expect(await stream.written == Data([2]))
    }

    // MARK: Server-side downscaling (Apple message type 8)

    @Test func serverScalingIsTenBytesWithABigEndianDouble() {
        #expect(ClientMessage.appleServerScaling(0.5).wireBytes == Data([8, 0, 0x3F, 0xE0, 0, 0, 0, 0, 0, 0]))
        #expect(ClientMessage.appleServerScaling(1).wireBytes == Data([8, 0, 0x3F, 0xF0, 0, 0, 0, 0, 0, 0]))
    }

    @Test func serverScalingNeverSendsAValueTheServerRejects() {
        // The server rejects ≤ 0 and > 1 (read from the binary): out-of-range values are clamped, NaN becomes 1.
        #expect(ClientMessage.appleServerScaling(3).wireBytes == ClientMessage.appleServerScaling(1).wireBytes)
        #expect(ClientMessage.appleServerScaling(.nan).wireBytes == ClientMessage.appleServerScaling(1).wireBytes)
        #expect(ClientMessage.appleServerScaling(-1).wireBytes == ClientMessage.appleServerScaling(0.05).wireBytes)
    }

    /// After downscaling, Apple's server sends only `DesktopSize` and waits: it must be re-requested in FULL (non-incrementally) at the new size.
    @Test func resizeIsFollowedByAFullRequestAtTheNewSize() async throws {
        let (s, stream) = try session(update(rectCount: 1, rectHeader(0, 0, 8, 6, encoding: -223)), pipelined: true)
        _ = try await s.nextEvent()
        let deadline = ContinuousClock.now + .seconds(5)
        while await stream.written.count < 20, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(await stream.written == Data([3, 1, 0, 0, 0, 0, 0, 4, 0, 2, 3, 0, 0, 0, 0, 0, 0, 8, 0, 6]))
    }

    // MARK: Frame cadence

    /// A request deferred on the old cadence (2 seconds) must go out immediately when the limit is removed, not wait out the 2 seconds.
    @Test func liftingTheLimitReleasesAnAlreadyDelayedRequest() async throws {
        let one = update(rectCount: 1, rectHeader(0, 0, 1, 1, encoding: 0) + bgra(1, 2, 3))
        let (s, stream) = try session(one + one, pipelined: true)
        await s.setMinimumUpdateInterval(.seconds(2))
        _ = try await s.nextEvent() // request 1 goes out immediately
        _ = try await s.nextEvent() // request 2 is deferred by 2 seconds
        let started = ContinuousClock.now
        await s.setMinimumUpdateInterval(nil)
        while await stream.written.count < 20, ContinuousClock.now - started < .seconds(3) { try await Task.sleep(for: .milliseconds(5)) }
        #expect(await stream.written.count == 20)
        // Well under the 2-second deferral, with headroom for a loaded machine (CI, parallel test processes).
        #expect(ContinuousClock.now - started < .milliseconds(1500))
    }

    // MARK: Cancelling during the handshake

    /// The server accepts the connection and then stays silent. Tapping Cancel (cancelling the Task) must exit immediately and close the socket, not hang until the timeout.
    @Test func cancellingDuringTheHandshakeReturnsPromptly() async throws {
        let listener = try NWListener(using: .tcp)
        let accepted = AcceptedConnections()
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            accepted.add(connection)
        }
        let ready = AsyncStream<UInt16> { continuation in
            listener.stateUpdateHandler = { if case .ready = $0, let port = listener.port?.rawValue { continuation.yield(port); continuation.finish() } }
        }
        listener.start(queue: .global())
        defer { listener.cancel(); accepted.cancelAll() }
        var port: UInt16 = 0
        for await value in ready { port = value }

        let task = Task {
            try await RFBConnection.open(host: "127.0.0.1", port: port, credentials: RFBCredentials(username: "", password: ""), timeout: .seconds(30))
        }
        try await Task.sleep(for: .milliseconds(300))
        let started = ContinuousClock.now
        task.cancel()
        _ = await task.result
        #expect(ContinuousClock.now - started < .seconds(2), "cancel must exit immediately, not wait 30 seconds")
    }
}

/// Holds the fake server-side connections so the test closes them itself.
private final class AcceptedConnections: @unchecked Sendable {
    private let lock = NSLock()
    private var connections: [NWConnection] = []
    func add(_ connection: NWConnection) { lock.withLock { connections.append(connection) } }
    func cancelAll() { lock.withLock { connections.forEach { $0.cancel() } } }
}
