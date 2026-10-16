import Foundation
import Network

/// One QUIC stream (an `NWConnection` extracted from an `NWConnectionGroup`).
final class QUICStream: LinkWireStream, @unchecked Sendable {
    let kind: LinkStreamKind
    private let connection: NWConnection
    private let lock = NSLock()
    private var leftover = Data()
    private var sawFin = false

    init(connection: NWConnection, kind: LinkStreamKind, leftover: Data = Data()) {
        self.connection = connection
        self.kind = kind
        self.leftover = leftover
    }

    func read() async throws -> Data? {
        let pending: Data? = lock.withLock {
            guard !leftover.isEmpty else { return nil }
            defer { leftover = Data() }
            return leftover
        }
        if let pending { return pending }
        if lock.withLock({ sawFin }) { return nil }
        while true {
            let chunk = try await receiveOnce()
            switch chunk {
            case .data(let d): return d
            case .fin: return nil
            case .empty: continue
            }
        }
    }

    enum Chunk { case data(Data), fin, empty }

    func receiveOnce() async throws -> Chunk {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Chunk, Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [self] data, _, isComplete, error in
                // A stream the peer has finished can report ENODATA ("No message available on STREAM") instead of, or along with,
                // `isComplete`, measured on loopback when the helper ends a window stream. It is the end of the stream, not a failure:
                // treating it as one dropped the whole link each time the iPad re-subscribed to a window.
                if case .posix(.ENODATA)? = error as NWError? {
                    lock.withLock { sawFin = true }
                    if let data, !data.isEmpty { cont.resume(returning: .data(data)) } else { cont.resume(returning: .fin) }
                    return
                }
                if let error { cont.resume(throwing: LinkWireError.network("\(error)")); return }
                if isComplete { lock.withLock { sawFin = true } }
                if let data, !data.isEmpty { cont.resume(returning: .data(data)) }
                else if isComplete { cont.resume(returning: .fin) }
                else { cont.resume(returning: .empty) }
            }
        }
    }

    /// Reads until a complete preamble is available; the bytes after it stay buffered for `read`.
    static func readPreamble(from connection: NWConnection) async throws -> QUICStream {
        let probe = QUICStream(connection: connection, kind: .control)
        var buffer = Data()
        while true {
            switch LinkStreamKind.parsePreamble(buffer) {
            case .invalid: throw LinkWireError.protocolViolation("stream preamble")
            case .complete(let kind, let consumed):
                return QUICStream(connection: connection, kind: kind, leftover: Data(buffer.dropFirst(consumed)))
            case .needMore: break
            }
            switch try await probe.receiveOnce() {
            case .data(let d): buffer.append(d)
            case .fin: throw LinkWireError.closed
            case .empty: continue
            }
            if buffer.count > LinkStreamKind.maxPreambleBytes * 2 + 64 * 1024 { throw LinkWireError.limit("preamble") }
        }
    }

    func write(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: data, contentContext: .defaultStream, isComplete: false, completion: .contentProcessed { error in
                if let error { cont.resume(throwing: LinkWireError.network("\(error)")) } else { cont.resume() }
            })
        }
    }

    func finish() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in cont.resume() })
        }
    }

    func abort() { connection.cancel() }
}

/// QUIC transport on Network.framework's classic API: an `NWConnectionGroup` over one QUIC connection.
final class QUICWire: LinkWire, @unchecked Sendable {
    let transport = LinkTransportKind.quic
    static let maxPendingPreambles = 16
    /// Tests shorten this; production leaves it at 10 s.
    nonisolated(unsafe) static var preambleTimeout: Duration = .seconds(10)

    private let group: NWConnectionGroup
    private let queue: DispatchQueue
    private let recorder: PeerVerifyRecorder
    /// The recorder is private to this (client) wire; a server shares one recorder across all its wires.
    private let ownsRecorder: Bool
    private let ready = OneShot<Void>()
    private let closedGate = OneShot<Void>()
    private let lock = NSLock()
    private var peerInfo: LinkPeerInfo?
    private var remoteKey: String?
    private var pendingPreambles = 0
    /// Live stream connections, so `close` can cancel them (resetting each stream) before the group goes.
    private var liveStreams: [ObjectIdentifier: NWConnection] = [:]
    let incomingStreams: AsyncStream<any LinkWireStream>
    private let incomingCont: AsyncStream<any LinkWireStream>.Continuation

    var peer: LinkPeerInfo { lock.withLock { peerInfo } ?? LinkPeerInfo(spkiHash: Data(), exporter: nil) }
    var remoteAddress: String { lock.withLock { remoteKey } ?? LinkRemoteAddress.unknown }

    /// QUIC parameters shared by client, server and listener.
    static func parameters(
        identity: LinkSecIdentity, policy: PinPolicy, recorder: PeerVerifyRecorder, queue: DispatchQueue
    ) -> NWParameters {
        let options = NWProtocolQUIC.Options(alpn: [LinkTransportInfo.alpn])
        LinkTLS.configure(options.securityProtocolOptions, identity: identity, policy: policy, recorder: recorder, queue: queue)
        options.initialMaxData = 64 << 20
        options.initialMaxStreamDataBidirectionalLocal = 16 << 20
        options.initialMaxStreamDataBidirectionalRemote = 16 << 20
        options.initialMaxStreamDataUnidirectional = 16 << 20
        options.initialMaxStreamsBidirectional = 8
        options.initialMaxStreamsUnidirectional = 128
        options.idleTimeout = 60_000
        let params = NWParameters(quic: options)
        params.serviceClass = .interactiveVideo
        return params
    }

    static func oneWayOptions() -> NWProtocolQUIC.Options {
        let o = NWProtocolQUIC.Options(alpn: [LinkTransportInfo.alpn])
        o.direction = .unidirectional
        return o
    }

    /// Client side: dial `endpoint`.
    convenience init(
        endpoint: NWEndpoint, identity: LinkSecIdentity, policy: PinPolicy, queue: DispatchQueue = DispatchQueue(label: "screon.link.quic")
    ) {
        let recorder = PeerVerifyRecorder()
        let params = Self.parameters(identity: identity, policy: policy, recorder: recorder, queue: queue)
        self.init(group: NWConnectionGroup(with: NWMultiplexGroup(to: endpoint), using: params), queue: queue, recorder: recorder, ownsRecorder: true)
    }

    /// Server side: wrap a group the listener handed us.
    init(group: NWConnectionGroup, queue: DispatchQueue, recorder: PeerVerifyRecorder, ownsRecorder: Bool = false) {
        self.ownsRecorder = ownsRecorder
        self.group = group
        self.queue = queue
        self.recorder = recorder
        (incomingStreams, incomingCont) = AsyncStream<any LinkWireStream>.makeStream(bufferingPolicy: .bufferingOldest(256))
    }

    func start(timeout: Duration) async throws {
        if ownsRecorder { recorder.setOnFailure { [ready] in ready.complete(.failure(LinkWireError.pinMismatch)) } }
        // Network.framework only starts a group that has a handler for incoming streams.
        group.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        group.setReceiveHandler { _, _, _ in }  // datagrams are not used in v1; the handler only exists so the group starts
        let deadline = StartDeadline()
        group.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            if case .waiting(let error) = state, StartDeadline.isLocalNetworkPolicy(error) { deadline.waiting(true) } else { deadline.waiting(false) }
            switch state {
            case .ready:
                self.captureHandshake()
                self.ready.complete(.success(()))
            case .failed(let error):
                self.fail(self.recorder.lastFailure != nil ? LinkWireError.pinMismatch : LinkWireError.network("\(error)"))
            case .cancelled:
                self.fail(LinkWireError.closed)
            default: break
            }
        }
        group.start(queue: queue)
        let timer = Task { [ready] in
            if await deadline.expire(after: timeout) { ready.complete(.failure(LinkWireError.timedOut)) }
        }
        defer { timer.cancel() }
        do { try await ready.wait() } catch {
            let mapped: Error = recorder.lastFailure != nil ? LinkWireError.pinMismatch : error
            close()
            throw mapped
        }
        guard lock.withLock({ peerInfo }) != nil else {
            close()
            throw LinkWireError.notReady("no peer certificate")
        }
    }

    private func captureHandshake() {
        guard let md = group.metadata(definition: NWProtocolQUIC.definition) as? NWProtocolQUIC.Metadata,
              let info = LinkTLS.peerInfo(from: md.securityProtocolMetadata)
        else { return }
        lock.withLock { peerInfo = info }
    }

    private func fail(_ error: Error) {
        ready.complete(.failure(error))
        closedGate.complete(.success(()))
        incomingCont.finish()
    }

    /// Network.framework hands the server one extra, silent `NWConnection` per QUIC connection (it never carries a preamble).
    /// Cancelling it tears the whole connection down, so no stream is ever cancelled for being slow: the connection is kept
    /// (and retained in `liveStreams` until the wire closes), it just stops counting against the preamble limit after
    /// `preambleTimeout`. The QUIC stream limits (`initialMaxStreams*`) bound how many such streams a peer can open.
    private func accept(_ connection: NWConnection) {
        track(connection)
        // The connection the listener hands over names the remote end; remember it for rate limiting.
        let key = LinkRemoteAddress.key(for: connection.currentPath?.remoteEndpoint ?? connection.endpoint)
        lock.withLock { if remoteKey == nil || remoteKey == LinkRemoteAddress.unknown { remoteKey = key } }
        connection.start(queue: queue)
        let slot = lock.withLock { () -> Bool in
            guard pendingPreambles < Self.maxPendingPreambles else { return false }
            pendingPreambles += 1
            return true
        }
        guard slot else { return }  // over the limit: left dormant, not read
        let release = ReleaseOnce { [weak self] in self?.lock.withLock { self?.pendingPreambles -= 1 } }
        let timer = Task {
            if await sleepUnlessCancelled(Self.preambleTimeout) { release.run() }
        }
        Task { [weak self] in
            do {
                let stream = try await QUICStream.readPreamble(from: connection)
                timer.cancel()
                release.run()
                self?.incomingCont.yield(stream)
            } catch {
                timer.cancel()
                release.run()
                // A malformed preamble is a protocol violation: take the whole connection down.
                if case LinkWireError.protocolViolation = error { self?.close() }
            }
        }
    }

    private func track(_ connection: NWConnection, onState: (@Sendable (NWConnection.State) -> Void)? = nil) {
        let id = ObjectIdentifier(connection)
        lock.withLock { liveStreams[id] = connection }
        connection.stateUpdateHandler = { [weak self] state in
            onState?(state)
            switch state {
            case .failed, .cancelled: self?.lock.withLock { _ = self?.liveStreams.removeValue(forKey: id) }
            default: break
            }
        }
    }


    func openStream(_ kind: LinkStreamKind) async throws -> any LinkWireStream {
        let stream = try await openRawStream(preamble: kind.preamble, bidirectional: kind.isBidirectional, kind: kind)
        return stream
    }

    /// Opens a stream and sends `preamble` as its first bytes. `openStream` is the only production caller; tests use this to
    /// send a malformed preamble.
    func openRawStream(preamble: Data, bidirectional: Bool, kind: LinkStreamKind) async throws -> QUICStream {
        let options: NWProtocolQUIC.Options? = bidirectional ? nil : Self.oneWayOptions()
        guard let connection = NWConnection(from: group, using: options) else { throw LinkWireError.notReady("cannot open stream") }
        let started = OneShot<Void>()
        track(connection, onState: { state in
            switch state {
            case .ready: started.complete(.success(()))
            case .failed(let e): started.complete(.failure(LinkWireError.network("\(e)")))
            case .cancelled: started.complete(.failure(LinkWireError.closed))
            default: break
            }
        })
        connection.start(queue: queue)
        try await started.wait()
        let stream = QUICStream(connection: connection, kind: kind)
        // A QUIC stream is invisible to the peer until the first byte is sent: send the preamble now.
        try await stream.write(preamble)
        return stream
    }

    func waitUntilClosed() async { _ = try? await closedGate.wait() }

    func close() {
        let streams = lock.withLock { () -> [NWConnection] in let s = Array(liveStreams.values); liveStreams = [:]; return s }
        for s in streams { s.cancel() }
        group.cancel()
        closedGate.complete(.success(()))
        ready.complete(.failure(LinkWireError.closed))
        incomingCont.finish()
    }
}

/// Runs a block at most once, from any thread.
final class ReleaseOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var block: (@Sendable () -> Void)?
    init(_ block: @escaping @Sendable () -> Void) { self.block = block }
    func run() {
        let b = lock.withLock { () -> (@Sendable () -> Void)? in defer { block = nil }; return block }
        b?()
    }
}
