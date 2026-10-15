import Foundation
import Network

extension NWParameters {
    /// TCP cho một phiên điều khiển từ xa.
    ///
    /// - **Keepalive** (20 s rảnh, rồi 3 lần thăm dò cách nhau 5 s): máy bên kia biến mất (Mac ngủ, Wi-Fi đổi) thì hệ thống
    ///   báo lỗi sau khoảng 35 giây. Không có nó, RFB khi màn hình đứng yên không gửi gì nên kết nối chết có thể treo hàng phút,
    ///   và việc tự kết nối lại không bao giờ được kích hoạt.
    /// - **`TCP_NODELAY`**: mỗi sự kiện chuột hay phím chỉ vài byte. Thuật toán Nagle gom chúng lại chờ ACK nên gây trễ thao tác.
    public static var rfbTCP: NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 20
        tcp.keepaliveInterval = 5
        tcp.keepaliveCount = 3
        return NWParameters(tls: nil, tcp: tcp)
    }
}

/// `ByteStream` chạy trên `NWConnection` (TCP).
public actor NWByteStream: ByteStream {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "RFBKit.NWByteStream")

    public init(host: String, port: UInt16, parameters: NWParameters = .rfbTCP) {
        // `port` là UInt16 nên `NWEndpoint.Port(rawValue:)` luôn thành công.
        let endpoint = NWEndpoint.Port(rawValue: port) ?? .any
        connection = NWConnection(host: NWEndpoint.Host(host), port: endpoint, using: parameters)
    }

    /// Nối tới một điểm cuối bất kỳ, ví dụ dịch vụ Bonjour `.service(...)`: hệ thống tự phân giải tên và địa chỉ.
    public init(endpoint: NWEndpoint, parameters: NWParameters = .rfbTCP) {
        connection = NWConnection(to: endpoint, using: parameters)
    }

    /// Lỗi `.waiting` mà hệ thống có thể tự gỡ nên đáng chờ: mạng chưa lên, chưa có đường tới địa chỉ,
    /// hoặc iOS đang chặn vì quyền **Mạng cục bộ** chưa được cấp (lỗi DNS `PolicyDenied`, -65570).
    ///
    /// Lần đầu kết nối tới máy trong mạng nội bộ, iOS hiện hộp thoại xin quyền và giữ kết nối ở `.waiting`
    /// tới khi người dùng chọn. Các lỗi còn lại (ví dụ từ chối kết nối, hết giờ) là câu trả lời dứt khoát
    /// của mạng nên không chờ thêm.
    static func isRecoverableWaitingError(_ error: NWError) -> Bool {
        switch error {
        case .posix(let code): [.ENETDOWN, .ENETUNREACH, .EHOSTUNREACH].contains(code)
        case .dns(let code): code == -65570
        default: false
        }
    }

    /// Mở kết nối và chờ tới khi sẵn sàng.
    ///
    /// - Parameter waitingPatience: thời gian chờ khi kết nối nằm ở `.waiting` vì một lỗi mà hệ thống có thể
    ///   tự gỡ (xem ``isRecoverableWaitingError(_:)``). Mặc định `.zero`: thất bại ngay, hợp với công cụ dòng lệnh.
    ///   Hết thời gian chờ thì ném chính lỗi mạng đã quan sát được, để giao diện nói được nguyên nhân thật.
    public func connect(waitingPatience: Duration = .zero) async throws {
        let (states, continuation) = AsyncStream<NWConnection.State>.makeStream()
        connection.stateUpdateHandler = { state in
            continuation.yield(state)
            switch state {
            case .ready, .failed, .cancelled: continuation.finish()
            default: break
            }
        }
        connection.start(queue: queue)

        var lastWaitingError: NWError?
        var patienceTimer: Task<Void, Never>?
        defer { patienceTimer?.cancel() }

        for await state in states {
            switch state {
            case .ready: return
            case .failed(let error): throw error
            case .cancelled: throw RFBError.connectionClosed
            case .waiting(let error):
                guard waitingPatience > .zero, Self.isRecoverableWaitingError(error) else { throw error }
                lastWaitingError = error
                if patienceTimer == nil {
                    patienceTimer = Task {
                        // Bị hủy (mạng vừa có lại, `.preparing`) thì sleep ném lỗi và ta KHÔNG kết thúc luồng trạng thái:
                        // nuốt lỗi bằng `try?` rồi vẫn `finish()` từng làm hỏng đúng lúc người dùng vừa cấp quyền Mạng cục bộ.
                        do {
                            try await Task.sleep(for: waitingPatience)
                            continuation.finish()
                        } catch {}
                    }
                }
            case .preparing:
                // Đường mạng đã có (ví dụ vừa được cấp quyền): ngừng đếm giờ và để kết nối tiến tiếp.
                patienceTimer?.cancel()
                patienceTimer = nil
            default: continue
            }
        }
        throw lastWaitingError ?? RFBError.connectionClosed
    }

    public func read(exactly count: Int) async throws -> Data {
        guard count > 0 else { return Data() }
        return try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let data, data.count == count {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: RFBError.connectionClosed)
                }
            }
        }
    }

    public func readSome(maxCount: Int) async throws -> Data {
        guard maxCount > 0 else { return Data() }
        return try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: maxCount) { data, _, _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: RFBError.connectionClosed)
                }
            }
        }
    }

    public func write(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    public func close() {
        connection.cancel()
    }

    /// Luồng bị bỏ mà chưa `close()` thì vẫn trả kết nối TCP, không để nó mở vô thời hạn.
    deinit {
        connection.cancel()
    }
}
