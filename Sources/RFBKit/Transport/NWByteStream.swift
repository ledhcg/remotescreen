import Foundation
import Network

extension NWParameters {
    /// TCP for a remote-control session.
    ///
    /// - **Keepalive** (20 s idle, then 3 probes 5 s apart): if the peer disappears (Mac sleeps, Wi-Fi changes), the system
    ///   reports an error after about 35 seconds. Without it, RFB sends nothing while the screen is idle, so a dead connection can hang for minutes,
    ///   and automatic reconnection would never be triggered.
    /// - **`TCP_NODELAY`**: each mouse or key event is only a few bytes. Nagle's algorithm batches them while waiting for an ACK, which delays input.
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

/// `ByteStream` running on `NWConnection` (TCP).
public actor NWByteStream: ByteStream {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "RFBKit.NWByteStream")

    public init(host: String, port: UInt16, parameters: NWParameters = .rfbTCP) {
        // `port` is a UInt16, so `NWEndpoint.Port(rawValue:)` always succeeds.
        let endpoint = NWEndpoint.Port(rawValue: port) ?? .any
        connection = NWConnection(host: NWEndpoint.Host(host), port: endpoint, using: parameters)
    }

    /// Connects to an arbitrary endpoint, for example a Bonjour `.service(...)`: the system resolves the name and address itself.
    public init(endpoint: NWEndpoint, parameters: NWParameters = .rfbTCP) {
        connection = NWConnection(to: endpoint, using: parameters)
    }

    /// `.waiting` errors that the system may clear on its own and so are worth waiting for: network not up yet, no route to the address,
    /// or iOS blocking because the **Local Network** permission has not been granted (DNS error `PolicyDenied`, -65570).
    ///
    /// On the first connection to a machine on the local network, iOS shows a permission dialog and holds the connection in `.waiting`
    /// until the user chooses. Other errors (for example connection refused, timeout) are a definitive answer
    /// from the network, so there is no extra waiting.
    static func isRecoverableWaitingError(_ error: NWError) -> Bool {
        switch error {
        case .posix(let code): [.ENETDOWN, .ENETUNREACH, .EHOSTUNREACH].contains(code)
        case .dns(let code): code == -65570
        default: false
        }
    }

    /// Opens the connection and waits until it is ready.
    ///
    /// - Parameter waitingPatience: how long to wait when the connection sits in `.waiting` because of an error the system may
    ///   clear itself (see ``isRecoverableWaitingError(_:)``). Defaults to `.zero`: fail immediately, which suits command-line tools.
    ///   When the wait times out, the network error actually observed is thrown, so the UI can state the real cause.
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
                        // If cancelled (network just came back, `.preparing`), sleep throws and we do NOT finish the state stream:
                        // swallowing the error with `try?` and still calling `finish()` once broke exactly when the user had just granted Local Network permission.
                        do {
                            try await Task.sleep(for: waitingPatience)
                            continuation.finish()
                        } catch {}
                    }
                }
            case .preparing:
                // A network path now exists (for example permission was just granted): stop the timer and let the connection proceed.
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

    /// A stream that is dropped without `close()` still releases the TCP connection, rather than leaving it open indefinitely.
    deinit {
        connection.cancel()
    }
}
