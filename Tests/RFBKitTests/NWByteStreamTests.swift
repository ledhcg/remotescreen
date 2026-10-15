import Foundation
import Network
import Testing
@testable import RFBKit

@Suite("NWByteStream: chờ mạng và phân loại lỗi")
struct NWByteStreamTests {
    @Test("Lỗi mạng chưa lên, chưa có đường, quyền Mạng cục bộ bị chặn: đáng chờ",
          arguments: [
              NWError.posix(.ENETDOWN),        // 50: lỗi người dùng gặp trên iPad
              NWError.posix(.ENETUNREACH),     // 51
              NWError.posix(.EHOSTUNREACH),    // 65
              NWError.dns(-65570),             // kDNSServiceErr_PolicyDenied: quyền Mạng cục bộ
          ])
    func recoverable(error: NWError) {
        #expect(NWByteStream.isRecoverableWaitingError(error))
    }

    @Test("Câu trả lời dứt khoát của mạng: không chờ",
          arguments: [
              NWError.posix(.ECONNREFUSED),    // Mac tắt Chia sẻ màn hình
              NWError.posix(.ETIMEDOUT),
              NWError.posix(.ECONNRESET),
              NWError.dns(-65554),             // kDNSServiceErr_NoSuchRecord: gõ sai tên máy
          ])
    func definitive(error: NWError) {
        #expect(!NWByteStream.isRecoverableWaitingError(error))
    }

    /// Bắt buộc: dù `NWConnection` báo "từ chối kết nối" qua `.failed` hay `.waiting`, người dùng đã cho phép
    /// chờ 20 giây vẫn phải thấy lỗi này **ngay**, không phải sau 20 giây.
    @Test("Cổng đóng: báo ECONNREFUSED ngay dù cho phép chờ lâu")
    func refusedIsImmediateEvenWithPatience() async throws {
        let port = try closedLoopbackPort()
        let stream = NWByteStream(host: "127.0.0.1", port: port)
        let started = ContinuousClock.now
        do {
            try await stream.connect(waitingPatience: .seconds(20))
            Issue.record("Không được kết nối thành công tới cổng đã đóng")
        } catch let error as NWError {
            #expect(error == .posix(.ECONNREFUSED))
        }
        let elapsed = ContinuousClock.now - started
        #expect(elapsed < .seconds(5), "mất \(elapsed): lỗi dứt khoát bị chờ như lỗi tạm thời")
        await stream.close()
    }

    /// Tìm một cổng loopback không ai nghe: mở một listener lấy cổng rồi đóng nó lại.
    private func closedLoopbackPort() throws -> UInt16 {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        try #require(bound == 0)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }
        try #require(named == 0)
        return UInt16(bigEndian: address.sin_port)
    }
}

@Suite("NWParameters.rfbTCP")
struct RFBTCPParametersTests {
    private var tcp: NWProtocolTCP.Options? {
        NWParameters.rfbTCP.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options
    }

    @Test func disablesNagleSoSmallInputEventsAreNotDelayed() throws {
        #expect(try #require(tcp).noDelay)
    }

    @Test func enablesKeepaliveSoADeadPeerIsNoticedInAboutHalfAMinute() throws {
        let tcp = try #require(tcp)
        #expect(tcp.enableKeepalive)
        #expect(tcp.keepaliveIdle == 20)
        #expect(tcp.keepaliveInterval == 5)
        #expect(tcp.keepaliveCount == 3)
        #expect(tcp.keepaliveIdle + tcp.keepaliveInterval * tcp.keepaliveCount <= 40, "phát hiện chậm nhất khoảng 35 giây")
    }

    @Test func aLiveConnectionStillWorksWithTheseParameters() async throws {
        // Dùng chính tham số này nối tới một listener thật trong tiến trình test, để chắc chúng không làm hỏng kết nối.
        let listener = try NWListener(using: .rfbTCP)
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            connection.send(content: Data("RFB 003.008\n".utf8), completion: .contentProcessed { _ in })
        }
        let ready = AsyncStream<UInt16> { continuation in
            listener.stateUpdateHandler = { state in
                if case .ready = state, let port = listener.port?.rawValue { continuation.yield(port); continuation.finish() }
            }
        }
        listener.start(queue: .global())
        defer { listener.cancel() }
        var portValue: UInt16 = 0
        for await value in ready { portValue = value }
        let stream = NWByteStream(host: "127.0.0.1", port: portValue)
        try await stream.connect()
        #expect(String(data: try await stream.read(exactly: 12), encoding: .utf8) == "RFB 003.008\n")
        await stream.close()
    }
}
