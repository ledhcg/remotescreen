import Foundation
import Network

/// One logical stream inside the TCP+TLS multiplex.
final class MuxStream: LinkWireStream, @unchecked Sendable {
    /// Bytes buffered for the reader before the wire's read loop pauses (TCP-level backpressure; head-of-line blocking is the
    /// price of this fallback).
    static let maxBufferedBytes = 2 << 20

    let kind: LinkStreamKind
    let id: UInt32
    private let wire: TCPMuxWire
    private let lock = NSLock()
    private var chunks: [Data] = []
    private var buffered = 0
    private var peerFinished: Bool
    private var localFinished: Bool
    private var failure: Error?
    private var readWaiter: CheckedContinuation<Void, Never>?
    private var spaceWaiter: CheckedContinuation<Void, Never>?

    /// `weOpened`: whether this side opened the stream; decides which directions exist.
    init(wire: TCPMuxWire, id: UInt32, kind: LinkStreamKind, weOpened: Bool) {
        self.wire = wire
        self.id = id
        self.kind = kind
        // A one-way stream has no bytes in the direction opposite to its opener.
        peerFinished = weOpened && !kind.isBidirectional
        localFinished = !weOpened && !kind.isBidirectional
    }

    // MARK: Inbound (called by the wire's read loop)

    func deliver(_ data: Data) async {
        let mustWait: Bool = lock.withLock {
            chunks.append(data)
            buffered += data.count
            let w = readWaiter
            readWaiter = nil
            w?.resume()
            return buffered > Self.maxBufferedBytes
        }
        guard mustWait else { return }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                let resumeNow: Bool = lock.withLock {
                    if buffered <= Self.maxBufferedBytes || failure != nil || Task.isCancelled { return true }
                    spaceWaiter = cont
                    return false
                }
                if resumeNow { cont.resume() }
            }
        } onCancel: {
            let cont: CheckedContinuation<Void, Never>? = lock.withLock { defer { spaceWaiter = nil }; return spaceWaiter }
            cont?.resume()
        }
    }

    func deliverFin() {
        lock.withLock {
            peerFinished = true
            let w = readWaiter; readWaiter = nil; w?.resume()
        }
        wire.noteStreamState(self)
    }

    func fail(_ error: Error) {
        lock.withLock {
            if failure == nil { failure = error }
            let w = readWaiter; readWaiter = nil; w?.resume()
            let s = spaceWaiter; spaceWaiter = nil; s?.resume()
        }
    }

    var isFullyFinished: Bool { lock.withLock { peerFinished && localFinished } }

    // MARK: LinkWireStream

    func read() async throws -> Data? {
        while true {
            enum Step { case data(Data), fin, error(Error), wait }
            let step: Step = lock.withLock {
                if !chunks.isEmpty {
                    let d = chunks.removeFirst()
                    buffered -= d.count
                    if buffered <= Self.maxBufferedBytes { let s = spaceWaiter; spaceWaiter = nil; s?.resume() }
                    return .data(d)
                }
                if let failure { return .error(failure) }
                if peerFinished { return .fin }
                return .wait
            }
            switch step {
            case .data(let d): return d
            case .fin: return nil
            case .error(let e): throw e
            case .wait:
                // A cancelled reader stops waiting and throws; before, it waited for data that might never come.
                try Task.checkCancellation()
                await withTaskCancellationHandler {
                    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                        let resumeNow: Bool = lock.withLock {
                            if !chunks.isEmpty || failure != nil || peerFinished || Task.isCancelled { return true }
                            readWaiter = cont
                            return false
                        }
                        if resumeNow { cont.resume() }
                    }
                } onCancel: {
                    let cont: CheckedContinuation<Void, Never>? = lock.withLock { defer { readWaiter = nil }; return readWaiter }
                    cont?.resume()
                }
            }
        }
    }

    func write(_ data: Data) async throws {
        if let f = lock.withLock({ failure }) { throw f }
        var offset = data.startIndex
        while offset < data.endIndex {
            let end = data.index(offset, offsetBy: LinkMux.maxDataBytes, limitedBy: data.endIndex) ?? data.endIndex
            try await wire.sendFrame(.data(streamID: id, data[offset..<end]))
            offset = end
        }
    }

    func finish() async {
        let already: Bool = lock.withLock { let a = localFinished; localFinished = true; return a }
        if !already { try? await wire.sendFrame(.fin(streamID: id)) }
        wire.noteStreamState(self)
    }

    func abort() {
        fail(LinkWireError.closed)
        wire.resetStream(self)
    }
}

/// TLS 1.3 over TCP carrying several logical streams (`LinkMux`). The fallback for networks that block UDP.
final class TCPMuxWire: LinkWire, @unchecked Sendable {
    let transport = LinkTransportKind.tcp

    private let connection: NWConnection
    private let queue: DispatchQueue
    private let recorder: PeerVerifyRecorder
    private let weAreClient: Bool
    private let ready = OneShot<Void>()
    private let closedGate = OneShot<Void>()
    private let lock = NSLock()
    private var peerInfo: LinkPeerInfo?
    private var table: LinkMuxStreamTable
    private var streams: [UInt32: MuxStream] = [:]
    private var readTask: Task<Void, Never>?
    let incomingStreams: AsyncStream<any LinkWireStream>
    private let incomingCont: AsyncStream<any LinkWireStream>.Continuation

    var peer: LinkPeerInfo { lock.withLock { peerInfo } ?? LinkPeerInfo(spkiHash: Data(), exporter: nil) }
    var remoteAddress: String {
        LinkRemoteAddress.key(for: connection.currentPath?.remoteEndpoint ?? connection.endpoint)
    }

    static func parameters(identity: LinkSecIdentity, policy: PinPolicy, recorder: PeerVerifyRecorder, queue: DispatchQueue) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        LinkTLS.configure(tls.securityProtocolOptions, identity: identity, policy: policy, recorder: recorder, queue: queue)
        sec_protocol_options_add_tls_application_protocol(tls.securityProtocolOptions, LinkTransportInfo.alpn)
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 15
        let params = NWParameters(tls: tls, tcp: tcp)
        params.serviceClass = .interactiveVideo
        return params
    }

    /// Client side.
    convenience init(
        endpoint: NWEndpoint, identity: LinkSecIdentity, policy: PinPolicy, queue: DispatchQueue = DispatchQueue(label: "screon.link.tcp")
    ) {
        let recorder = PeerVerifyRecorder()
        let params = Self.parameters(identity: identity, policy: policy, recorder: recorder, queue: queue)
        self.init(connection: NWConnection(to: endpoint, using: params), queue: queue, recorder: recorder, weAreClient: true)
    }

    /// Server side (connection from a TLS listener) or client side with a prepared connection.
    init(connection: NWConnection, queue: DispatchQueue, recorder: PeerVerifyRecorder, weAreClient: Bool) {
        self.connection = connection
        self.queue = queue
        self.recorder = recorder
        self.weAreClient = weAreClient
        table = LinkMuxStreamTable(weAreClient: weAreClient)
        (incomingStreams, incomingCont) = AsyncStream<any LinkWireStream>.makeStream(bufferingPolicy: .bufferingOldest(256))
    }

    func start(timeout: Duration) async throws {
        if weAreClient { recorder.setOnFailure { [ready] in ready.complete(.failure(LinkWireError.pinMismatch)) } }
        let deadline = StartDeadline()
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            if case .waiting(let error) = state, StartDeadline.isLocalNetworkPolicy(error) { deadline.waiting(true) } else { deadline.waiting(false) }
            switch state {
            case .ready:
                if let md = self.connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata,
                   let info = LinkTLS.peerInfo(from: md.securityProtocolMetadata) {
                    self.lock.withLock { self.peerInfo = info }
                    self.ready.complete(.success(()))
                } else {
                    self.ready.complete(.failure(LinkWireError.notReady("no peer certificate")))
                }
            case .waiting(let error):
                // A refused connection is final for our purposes; other waiting states may recover.
                if case .posix(let code) = error, code == .ECONNREFUSED { self.fail(LinkWireError.network("refused")) }
            case .failed(let error):
                self.fail(self.recorder.lastFailure != nil ? LinkWireError.pinMismatch : LinkWireError.network("\(error)"))
            case .cancelled:
                self.fail(LinkWireError.closed)
            default: break
            }
        }
        connection.start(queue: queue)
        let timer = Task { [ready] in
            if await deadline.expire(after: timeout) { ready.complete(.failure(LinkWireError.timedOut)) }
        }
        defer { timer.cancel() }
        do { try await ready.wait() } catch {
            let mapped: Error = recorder.lastFailure != nil ? LinkWireError.pinMismatch : error
            close()
            throw mapped
        }
        readTask = Task { [weak self] in await self?.readLoop() }
    }

    private func fail(_ error: Error) {
        ready.complete(.failure(error))
        closedGate.complete(.success(()))
        incomingCont.finish()
        let all = lock.withLock { () -> [MuxStream] in let s = Array(streams.values); streams = [:]; return s }
        for s in all { s.fail(error) }
    }

    // MARK: Reading

    private func receiveOnce() async throws -> Data? {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data?, Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
                if let error { cont.resume(throwing: LinkWireError.network("\(error)")); return }
                if let data, !data.isEmpty { cont.resume(returning: data) }
                else if isComplete { cont.resume(returning: nil) }
                else { cont.resume(returning: Data()) }
            }
        }
    }

    private func readLoop() async {
        var decoder = LinkMuxDecoder()
        do {
            while let chunk = try await receiveOnce() {
                for frame in try decoder.feed(chunk) { try await handle(frame) }
            }
            fail(LinkWireError.closed)
        } catch let error as LinkMuxError {
            fail(LinkWireError.protocolViolation("\(error)"))
            close()
        } catch {
            fail(error)
        }
        connection.cancel()
    }

    private func handle(_ frame: LinkMuxFrame) async throws {
        switch frame {
        case .open(let id, let kind):
            let stream = try lock.withLock { () -> MuxStream in
                try table.peerOpens(id: id, kind: kind)
                let s = MuxStream(wire: self, id: id, kind: kind, weOpened: false)
                streams[id] = s
                return s
            }
            incomingCont.yield(stream)
        case .data(let id, let bytes):
            let target: MuxStream? = try lock.withLock {
                switch try table.peerData(id: id) {
                case .accept: return streams[id]
                case .ignore: return nil
                }
            }
            if let target { await target.deliver(bytes) }
        case .fin(let id):
            let target: MuxStream? = try lock.withLock {
                try table.peerFinishes(id: id)
                return streams[id]
            }
            target?.deliverFin()
        case .reset(let id):
            let target = lock.withLock { () -> MuxStream? in
                table.peerResets(id: id)
                return streams.removeValue(forKey: id)
            }
            target?.fail(LinkWireError.closed)
        }
    }

    // MARK: Writing

    func sendFrame(_ frame: LinkMuxFrame) async throws {
        let data = LinkMuxEncoder.encode(frame)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { cont.resume(throwing: LinkWireError.network("\(error)")) } else { cont.resume() }
            })
        }
    }

    func noteStreamState(_ stream: MuxStream) {
        guard stream.isFullyFinished else { return }
        lock.withLock {
            guard streams.removeValue(forKey: stream.id) != nil else { return }
            table.removeStream(id: stream.id)
        }
    }

    func resetStream(_ stream: MuxStream) {
        let known = lock.withLock { () -> Bool in
            guard streams.removeValue(forKey: stream.id) != nil else { return false }
            table.removeStream(id: stream.id)
            return true
        }
        if known { Task { try? await self.sendFrame(.reset(streamID: stream.id)) } }
    }

    func openStream(_ kind: LinkStreamKind) async throws -> any LinkWireStream {
        // Allocating the id and queueing the `open` frame happen under one lock, so ids reach the peer in increasing order
        // even when several tasks open streams at once.
        let box = Box<MuxStream?>(nil)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            lock.withLock {
                do {
                    let id = try table.allocateOurID()
                    table.weOpened(id: id, kind: kind)
                    let s = MuxStream(wire: self, id: id, kind: kind, weOpened: true)
                    streams[id] = s
                    box.value = s
                    connection.send(content: LinkMuxEncoder.encode(.open(streamID: id, kind: kind)), completion: .contentProcessed { error in
                        if let error { cont.resume(throwing: LinkWireError.network("\(error)")) } else { cont.resume() }
                    })
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
        guard let stream = box.value else { throw LinkWireError.closed }
        return stream
    }

    func waitUntilClosed() async { _ = try? await closedGate.wait() }

    func close() {
        connection.cancel()
        closedGate.complete(.success(()))
        ready.complete(.failure(LinkWireError.closed))
        incomingCont.finish()
        readTask?.cancel()
    }
}

final class Box<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}
