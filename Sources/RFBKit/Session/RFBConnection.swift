import Foundation
import Network
import os

/// Chạy `operation` với giới hạn thời gian và **kết quả lỗi xác định**.
///
/// Khi hết giờ, `onTimeout` được gọi trước (để đóng luồng, vì đọc qua `NWConnection` không tự hủy theo `Task`),
/// rồi lỗi luôn là `RFBError.timedOut`. Nếu không có cờ phân biệt thì lỗi "luồng bị đóng" do chính `onTimeout`
/// gây ra có thể lọt ra ngoài thay cho lỗi hết giờ, tùy việc nhánh nào kết thúc trước.
func withDeadline<T: Sendable>(
    _ timeout: Duration,
    onTimeout: @escaping @Sendable () async -> Void,
    _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    let fired = OSAllocatedUnfairLock(initialState: false)
    do {
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: timeout)
                fired.withLock { $0 = true }
                await onTimeout()
                throw RFBError.timedOut
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw RFBError.timedOut }
            return result
        }
    } catch {
        if fired.withLock({ $0 }) { throw RFBError.timedOut }
        throw error
    }
}

/// Mở kết nối RFB hoàn chỉnh: TCP, handshake, chọn security type, xác thực và `ServerInit`.
public enum RFBConnection {
    /// Chọn security type dùng được. Trả `nil` nếu server không cung cấp type phù hợp.
    ///
    /// - Có tên tài khoản: **chỉ** Apple Remote Desktop (type 30). Không hạ xuống VNC Authentication hay None, vì server
    ///   (hoặc kẻ ở giữa) có thể chỉ chào type yếu hơn: lúc đó phản hồi DES của thử thách có thể bị bẻ offline, và
    ///   người dùng tưởng mình đang đăng nhập bằng tài khoản. Muốn dùng mật khẩu VNC, người dùng phải bỏ trống tên
    ///   tài khoản; đó là lựa chọn rõ ràng của họ.
    /// - Không có tên tài khoản: VNC Authentication, rồi None. Chọn None sau cùng, để một server cho phép cả mật khẩu
    ///   lẫn không mật khẩu thì ta vẫn xác thực.
    public static func chooseSecurityType(from offered: [RFBSecurityType], hasUsername: Bool) -> RFBSecurityType? {
        let preference: [RFBSecurityType] = hasUsername
            ? [.appleRemoteDesktop]
            : [.vncAuthentication, .noAuthentication]
        return preference.first(where: offered.contains)
    }

    /// Kết nối tới `host:port` rồi trả về một phiên đã sẵn sàng (chưa gửi `SetEncodings`).
    ///
    /// - Parameters:
    ///   - timeout: tổng thời gian cho TCP, handshake, xác thực và `ServerInit`.
    ///   - networkPatience: thời gian chờ khi chưa có đường mạng hoặc quyền Mạng cục bộ chưa được cấp (hộp thoại
    ///     của iOS đang chờ người dùng). Nên nhỏ hơn `timeout`, nếu không lỗi mạng thật sẽ bị thay bằng `timedOut`.
    public static func open(
        host: String,
        port: UInt16 = 5900,
        credentials: RFBCredentials,
        shared: Bool = true,
        timeout: Duration = .seconds(30),
        networkPatience: Duration = .seconds(20),
        pixelFormat: PixelFormat = .bgra8888
    ) async throws -> RFBSession {
        try await open(
            over: NWByteStream(host: host, port: port), credentials: credentials, shared: shared,
            timeout: timeout, networkPatience: networkPatience, pixelFormat: pixelFormat
        )
    }

    /// Như `open(host:port:...)` nhưng nối tới một điểm cuối bất kỳ, ví dụ dịch vụ Bonjour.
    public static func open(
        endpoint: NWEndpoint,
        credentials: RFBCredentials,
        shared: Bool = true,
        timeout: Duration = .seconds(30),
        networkPatience: Duration = .seconds(20),
        pixelFormat: PixelFormat = .bgra8888
    ) async throws -> RFBSession {
        try await open(
            over: NWByteStream(endpoint: endpoint), credentials: credentials, shared: shared,
            timeout: timeout, networkPatience: networkPatience, pixelFormat: pixelFormat
        )
    }

    private static func open(
        over stream: NWByteStream,
        credentials: RFBCredentials,
        shared: Bool,
        timeout: Duration,
        networkPatience: Duration,
        pixelFormat: PixelFormat
    ) async throws -> RFBSession {
        do {
            // Đọc qua NWConnection không tự dừng khi Task bị hủy; bị hủy (người dùng bấm Hủy) thì đóng luồng để các lần đọc
            // đang chờ thoát ra ngay, không treo tới khi server trả lời.
            let (info, flavor, securityType) = try await withTaskCancellationHandler {
                try await withDeadline(timeout, onTimeout: { await stream.close() }) {
                try await stream.connect(waitingPatience: networkPatience)
                let hello = try await Handshake.readServerHello(over: stream)
                guard let type = chooseSecurityType(from: hello.securityTypes, hasUsername: !credentials.username.isEmpty) else {
                    throw RFBError.noCompatibleSecurityType(offered: hello.securityTypes)
                }
                try await Handshake.selectSecurityType(type, version: hello.negotiatedVersion, over: stream)
                try await Authenticator.authenticate(
                    type: type, version: hello.negotiatedVersion, credentials: credentials, over: stream
                )
                let info = try await Handshake.performInit(shared: shared, over: stream)
                return (info, ServerFlavor(serverVersion: hello.serverVersion), type)
                }
            } onCancel: {
                Task { await stream.close() }
            }
            return try RFBSession(stream: stream, serverInfo: info, flavor: flavor, pipelinesUpdateRequests: true, pixelFormat: pixelFormat, securityType: securityType)
        } catch {
            await stream.close()
            throw error
        }
    }
}
