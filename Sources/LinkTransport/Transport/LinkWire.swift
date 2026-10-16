import Foundation
import Network

/// Which transport carries a connection.
public enum LinkTransportKind: Sendable, Equatable {
    /// QUIC (UDP): one QUIC stream per logical stream.
    case quic
    /// TLS 1.3 over TCP with the logical streams multiplexed (see `LinkMux`).
    case tcp
}

/// Failures of the byte transport. User-facing mapping happens in `LinkSessionError`.
enum LinkWireError: Error, Equatable {
    case notReady(String)
    case timedOut
    case closed
    case pinMismatch
    case protocolViolation(String)
    case limit(String)
    case network(String)
}

/// A secured, multiplexed connection to the peer, with streams already tied to `LinkStreamKind`.
protocol LinkWire: AnyObject, Sendable {
    var transport: LinkTransportKind { get }
    /// Valid after `start` returned.
    var peer: LinkPeerInfo { get }
    /// Where the peer connects from, normalised for rate limiting (see `LinkRemoteAddress`); `"unknown"` when not known.
    var remoteAddress: String { get }
    /// Streams the peer opened, once their preamble is read. Finishes when the connection ends.
    var incomingStreams: AsyncStream<any LinkWireStream> { get }
    func start(timeout: Duration) async throws
    func openStream(_ kind: LinkStreamKind) async throws -> any LinkWireStream
    /// Completes when the connection is gone (peer closed, failure, or `close`).
    func waitUntilClosed() async
    /// Cancels everything immediately.
    func close()
}

protocol LinkWireStream: AnyObject, Sendable {
    var kind: LinkStreamKind { get }
    /// Next bytes from the peer; `nil` once the peer finished the stream. One outstanding read at a time. Throws when the
    /// stream or connection failed.
    func read() async throws -> Data?
    /// Completes when the bytes were handed to the transport.
    func write(_ data: Data) async throws
    /// Half-close: no more writes from us.
    func finish() async
    /// Abandon the stream in both directions.
    func abort()
}

/// A value that is set once and awaited by any number of tasks.
final class OneShot<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<T, Error>?
    private var waiters: [CheckedContinuation<T, Error>] = []

    /// The first call wins.
    func complete(_ r: Result<T, Error>) {
        let toResume: [CheckedContinuation<T, Error>] = lock.withLock {
            guard result == nil else { return [] }
            result = r
            defer { waiters = [] }
            return waiters
        }
        for w in toResume { w.resume(with: r) }
    }

    var isComplete: Bool { lock.withLock { result != nil } }

    func wait() async throws -> T {
        try await withCheckedThrowingContinuation { cont in
            let done: Result<T, Error>? = lock.withLock {
                if let result { return result }
                waiters.append(cont)
                return nil
            }
            if let done { cont.resume(with: done) }
        }
    }
}

/// Sleeps for `d`. Returns `false` when the task was cancelled first, so timers can tell expiry from cancellation.
func sleepUnlessCancelled(_ d: Duration) async -> Bool {
    do { try await Task.sleep(for: d); return true } catch { return false }
}
