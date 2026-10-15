import Foundation
import Network
import Testing
@testable import RFBKit

/// Các lỗi tìm thấy khi rà soát (audit) dự án, mỗi test giữ một lỗi không quay lại.
@Suite("Audit: giao thức và an toàn")
struct AuditFixTests {
    private func session(_ incoming: [UInt8], format: PixelFormat = .bgra8888, width: UInt16 = 4, height: UInt16 = 2,
                         pipelined: Bool = false) throws -> (RFBSession, ScriptedByteStream) {
        let stream = ScriptedByteStream(incoming)
        let info = ServerInit(width: width, height: height, pixelFormat: .bgra8888, name: "t")
        return (try RFBSession(stream: stream, serverInfo: info, pipelinesUpdateRequests: pipelined, pixelFormat: format), stream)
    }

    // MARK: Con trỏ ở 16 bit

    /// Trước đây luôn đọc 4 byte mỗi pixel: con trỏ 2x2 ở 16 bit làm lệch luồng và tiếng chuông phía sau thành rác.
    @Test func cursorPixelsFollowTheClientPixelFormatIn16Bit() async throws {
        let pixels: [UInt8] = [0x00, 0xF8, 0x00, 0xF8, 0x1F, 0x00, 0x1F, 0x00] // đỏ, đỏ, lam, lam (RGB565 LE)
        let mask: [UInt8] = [0b1100_0000, 0b1100_0000]
        let body = rectHeader(1, 1, 2, 2, encoding: -239) + pixels + mask
        let (s, _) = try session(update(rectCount: 1, body) + [2], format: .rgb565)
        guard case .framebufferUpdate(_, let cursor?) = try await s.nextEvent() else {
            Issue.record("không nhận được hình con trỏ"); return
        }
        #expect(cursor.width == 2 && cursor.height == 2)
        #expect(try await s.nextEvent() == .bell, "luồng phải còn thẳng hàng sau con trỏ")
    }

    // MARK: Clipboard quá lớn

    @Test func oversizedServerCutTextIsSkippedWithoutDroppingTheSession() async throws {
        let length = RFBSession.maxCutTextLength + 10
        var incoming: [UInt8] = [3, 0, 0, 0]
        incoming += withUnsafeBytes(of: UInt32(length).bigEndian) { Array($0) }
        incoming += [UInt8](repeating: 0x41, count: length)
        incoming += [2] // chuông ngay sau
        let (s, _) = try session(incoming)
        #expect(try await s.nextEvent() == .clipboardSkipped(bytes: length))
        #expect(try await s.nextEvent() == .bell)
    }

    @Test func oversizedAppleClipboardIsSkippedWithoutInflating() async throws {
        let compressed = 1000
        var incoming: [UInt8] = [31, 0, 0, 0]
        incoming += withUnsafeBytes(of: UInt32(7).bigEndian) { Array($0) }                     // mã
        incoming += withUnsafeBytes(of: UInt32(ClipboardTransfer.maxUncompressed + 1).bigEndian) { Array($0) }
        incoming += withUnsafeBytes(of: UInt32(compressed).bigEndian) { Array($0) }
        incoming += [UInt8](repeating: 0xEE, count: compressed)                                // không phải zlib hợp lệ: không được giải nén
        incoming += [2]
        let (s, _) = try session(incoming)
        #expect(try await s.nextEvent() == .clipboardSkipped(bytes: ClipboardTransfer.maxUncompressed + 1))
        #expect(try await s.nextEvent() == .bell)
    }

    // MARK: Trần bộ nhớ

    @Test func hugeFramebuffersAreRefusedButAn8KScreenIsFine() throws {
        #expect(throws: RFBError.self) { _ = try Framebuffer(width: 16_384, height: 16_384) }
        _ = try Framebuffer(width: 7680, height: 4320) // 8K
    }

    // MARK: CopyRect

    /// Đối chiếu với cách làm hiển nhiên (chụp vùng nguồn trước rồi mới ghi) trên nhiều kiểu chồng lấn.
    @Test(arguments: [(0, 0, 2, 1), (2, 1, 0, 0), (1, 0, 0, 0), (0, 0, 1, 0), (0, 1, 0, 0), (0, 0, 0, 1), (1, 1, 1, 0)])
    func copyRectMatchesASnapshotCopyForAnyOverlap(sx: Int, sy: Int, dx: Int, dy: Int) throws {
        let width = 5, height = 4
        var buffer = try Framebuffer(width: width, height: height)
        let pattern: [UInt8] = (0..<width * height).flatMap { i -> [UInt8] in [UInt8(i), UInt8((i * 3) & 0xFF), UInt8((i * 7) & 0xFF), 0] }
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

    // MARK: Thu nhỏ phía server (message loại 8 của Apple)

    @Test func serverScalingIsTenBytesWithABigEndianDouble() {
        #expect(ClientMessage.appleServerScaling(0.5).wireBytes == Data([8, 0, 0x3F, 0xE0, 0, 0, 0, 0, 0, 0]))
        #expect(ClientMessage.appleServerScaling(1).wireBytes == Data([8, 0, 0x3F, 0xF0, 0, 0, 0, 0, 0, 0]))
    }

    @Test func serverScalingNeverSendsAValueTheServerRejects() {
        // Server từ chối ≤ 0 và > 1 (đọc từ binary): giá trị ngoài khoảng được kẹp, NaN thành 1.
        #expect(ClientMessage.appleServerScaling(3).wireBytes == ClientMessage.appleServerScaling(1).wireBytes)
        #expect(ClientMessage.appleServerScaling(.nan).wireBytes == ClientMessage.appleServerScaling(1).wireBytes)
        #expect(ClientMessage.appleServerScaling(-1).wireBytes == ClientMessage.appleServerScaling(0.05).wireBytes)
    }

    /// Server Apple sau khi thu nhỏ chỉ gửi `DesktopSize` rồi chờ: phải xin lại TOÀN BỘ (không tăng dần) ở cỡ mới.
    @Test func resizeIsFollowedByAFullRequestAtTheNewSize() async throws {
        let (s, stream) = try session(update(rectCount: 1, rectHeader(0, 0, 8, 6, encoding: -223)), pipelined: true)
        _ = try await s.nextEvent()
        let deadline = ContinuousClock.now + .seconds(5)
        while await stream.written.count < 20, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(await stream.written == Data([3, 1, 0, 0, 0, 0, 0, 4, 0, 2, 3, 0, 0, 0, 0, 0, 0, 8, 0, 6]))
    }

    // MARK: Nhịp khung hình

    /// Yêu cầu đã bị hoãn theo nhịp cũ (2 giây) phải đi ngay khi bỏ giới hạn, không chờ hết 2 giây.
    @Test func liftingTheLimitReleasesAnAlreadyDelayedRequest() async throws {
        let one = update(rectCount: 1, rectHeader(0, 0, 1, 1, encoding: 0) + bgra(1, 2, 3))
        let (s, stream) = try session(one + one, pipelined: true)
        await s.setMinimumUpdateInterval(.seconds(2))
        _ = try await s.nextEvent() // yêu cầu 1 đi ngay
        _ = try await s.nextEvent() // yêu cầu 2 bị hoãn 2 giây
        let started = ContinuousClock.now
        await s.setMinimumUpdateInterval(nil)
        while await stream.written.count < 20, ContinuousClock.now - started < .seconds(3) { try await Task.sleep(for: .milliseconds(5)) }
        #expect(await stream.written.count == 20)
        #expect(ContinuousClock.now - started < .milliseconds(500))
    }

    // MARK: Hủy giữa lúc bắt tay

    /// Server nhận kết nối rồi im lặng. Bấm Hủy (hủy Task) phải thoát ngay và đóng socket, không treo tới hết thời gian chờ.
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
        #expect(ContinuousClock.now - started < .seconds(2), "hủy phải thoát ngay, không chờ 30 giây")
    }
}

/// Giữ các kết nối phía server giả để test tự đóng chúng.
private final class AcceptedConnections: @unchecked Sendable {
    private let lock = NSLock()
    private var connections: [NWConnection] = []
    func add(_ connection: NWConnection) { lock.withLock { connections.append(connection) } }
    func cancelAll() { lock.withLock { connections.forEach { $0.cancel() } } }
}
