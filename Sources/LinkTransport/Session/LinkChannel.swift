import Foundation
import LinkProtocol

/// Things that happen on a link connection besides messages.
public enum LinkEvent: Sendable {
    /// The peer opened a stream. Read its messages from the inbox.
    case streamOpened(LinkStreamKind, LinkInbox<LinkMessage>)
    /// The peer finished a stream cleanly (for example when it stops sending a window).
    case streamFinished(LinkStreamKind)
    /// The outbound video queue of a window fell behind and dropped frames. When `needsKeyframe` is true the encoder should
    /// produce a key frame now: everything after the dropped frames would otherwise be undecodable.
    case videoBackpressure(window: WindowID, droppedFrames: Int, needsKeyframe: Bool)
    /// The connection ended. `nil` means a clean local close.
    case closed(LinkSessionError?)
}

/// Runs `operation` and gives up after `d`, returning `nil`. The operation keeps running in the background if it does not
/// observe cancellation, but the caller is released on time (a task group would wait for it).
func withTimeout<T: Sendable>(_ d: Duration, _ operation: @escaping @Sendable () async -> T) async -> T? {
    let gate = OneShot<T?>()
    let work = Task { gate.complete(.success(await operation())) }
    let timer = Task { if await sleepUnlessCancelled(d) { gate.complete(.success(nil)) } }
    let result = (try? await gate.wait()) ?? nil
    work.cancel()
    timer.cancel()
    return result
}

/// Moves framed messages between a `LinkWire` and the session layer, for both roles: routes messages to streams, runs one
/// reader and one writer task per stream, enforces the direction and stream rules, applies the outbound queue policies
/// and tears everything down on the first failure. It contains no handshake or pairing logic.
actor LinkChannel {
    enum Role { case client, helper }

    static let maxIncomingWindowStreams = 128

    private final class Stream: @unchecked Sendable {  // mutated only on the channel actor
        let kind: LinkStreamKind
        let wire: any LinkWireStream
        var queue: LinkOutboundQueue
        let inbox = LinkInbox<LinkMessage>()
        let wakeups: AsyncStream<Void>
        let wake: AsyncStream<Void>.Continuation
        let writable: Bool
        let readable: Bool
        var closing = false
        let drained = OneShot<Void>()
        var tasks: [Task<Void, Never>] = []

        init(kind: LinkStreamKind, wire: any LinkWireStream, openedByUs: Bool) {
            self.kind = kind
            self.wire = wire
            writable = openedByUs || kind.isBidirectional
            readable = !openedByUs || kind.isBidirectional
            let policy: LinkOutboundQueue.Policy
            switch kind {
            case .control: policy = LinkOutboundQueue.Policy.control
            case .input: policy = LinkOutboundQueue.Policy.input
            case .window: policy = LinkOutboundQueue.Policy.windowVideo
            case .audio: policy = LinkOutboundQueue.Policy.audio
            }
            queue = LinkOutboundQueue(policy: policy)
            (wakeups, wake) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        }
    }

    let role: Role
    private let wire: any LinkWire
    nonisolated let events: AsyncStream<LinkEvent>
    private let eventsCont: AsyncStream<LinkEvent>.Continuation
    private var streams: [LinkStreamKind: Stream] = [:]
    private var opening: [LinkStreamKind: Task<Stream, Error>] = [:]
    private var closed = false
    /// `terminate` is draining the control queue: the peer is being shut out and nothing it sends is acted on any more.
    private var terminating = false
    private var established = false
    private(set) var failure: LinkSessionError?
    private let controlReady = OneShot<LinkInbox<LinkMessage>>()
    private let closedGate = OneShot<Void>()
    private var acceptTask: Task<Void, Never>?
    private var watchTask: Task<Void, Never>?

    init(wire: any LinkWire, role: Role) {
        self.wire = wire
        self.role = role
        (events, eventsCont) = AsyncStream<LinkEvent>.makeStream(bufferingPolicy: .unbounded)
    }

    var transport: LinkTransportKind { wire.transport }
    var peer: LinkPeerInfo { wire.peer }
    var isClosed: Bool { closed }

    func start() {
        let wire = self.wire
        acceptTask = Task { [weak self] in
            for await stream in wire.incomingStreams { await self?.accept(stream) }
        }
        watchTask = Task { [weak self] in
            await wire.waitUntilClosed()
            await self?.fail(.transport("connection lost"), notify: false)
        }
    }

    /// The control stream's inbox. On the helper this waits for the iPad to open the stream.
    func controlInbox() async throws -> LinkInbox<LinkMessage> {
        if let s = streams[.control] { return s.inbox }
        return try await controlReady.wait()
    }

    func waitUntilClosed() async { _ = try? await closedGate.wait() }

    /// Test hook: writes `bytes` straight to the wire stream of `kind`, bypassing encoding, queues and validation.
    func writeRawForTesting(_ bytes: Data, on kind: LinkStreamKind) async throws {
        guard let s = streams[kind] else { throw LinkSessionError.closed }
        try await s.wire.write(bytes)
    }

    func inbox(for kind: LinkStreamKind) -> LinkInbox<LinkMessage>? { streams[kind]?.inbox }

    // MARK: Sending

    func send(_ message: LinkMessage) async throws {
        guard !closed else { throw failure ?? LinkSessionError.closed }
        guard let kind = LinkMessageRules.streamKind(for: message) else { throw LinkSessionError.protocolViolation("no stream for message") }
        let direction = LinkMessageRules.direction(of: message.type)
        if (direction == .clientToHelper && role == .helper) || (direction == .helperToClient && role == .client) {
            throw LinkSessionError.protocolViolation("\(message.type) cannot be sent by this side")
        }
        let encoded: Data
        do { encoded = try LinkFrameEncoder.encode(message) } catch { throw LinkSessionError.protocolViolation("cannot encode \(message.type)") }
        let stream = try await ensureStream(kind)
        guard stream.writable, !stream.closing else { throw LinkSessionError.closed }
        let outcome: LinkOutboundQueue.Outcome
        do { outcome = try stream.queue.enqueue(message, encoded: encoded) } catch { throw LinkSessionError.queueFull }
        if outcome.dropped > 0, case .window(let id) = kind {
            eventsCont.yield(.videoBackpressure(window: id, droppedFrames: outcome.dropped, needsKeyframe: outcome.needsKeyframe))
        }
        stream.wake.yield()
    }

    /// Called when the handshake is over: from now on handshake and pairing messages are protocol violations.
    func markEstablished() { established = true }

    /// Opens the input stream (client only) so the peer sees it before the first input event.
    func openInputStream() async throws { _ = try await ensureStream(.input) }

    /// Finishes a stream after its queue drained (for example when the iPad unsubscribes from a window).
    func finishStream(_ kind: LinkStreamKind) async {
        guard let s = streams[kind], s.writable, !s.closing else { return }
        s.closing = true
        s.wake.yield()
        _ = await withTimeout(.seconds(2)) { _ = try? await s.drained.wait() }
        if !s.readable { remove(s) }
    }

    private func ensureStream(_ kind: LinkStreamKind) async throws -> Stream {
        if let s = streams[kind] { return s }
        let weOpenThisKind = kind.openedByClient == (role == .client)
        guard weOpenThisKind else { throw LinkSessionError.protocolViolation("stream \(kind) is opened by the peer") }
        if let task = opening[kind] { return try await task.value }
        let task = Task { try await self.openLocal(kind) }
        opening[kind] = task
        defer { opening[kind] = nil }
        return try await task.value
    }

    private func openLocal(_ kind: LinkStreamKind) async throws -> Stream {
        let ws: any LinkWireStream
        do { ws = try await wire.openStream(kind) } catch { throw LinkSessionError.transport("cannot open stream") }
        guard !closed else { ws.abort(); throw failure ?? LinkSessionError.closed }
        if let existing = streams[kind] { return existing }
        return register(Stream(kind: kind, wire: ws, openedByUs: true))
    }

    private func register(_ s: Stream) -> Stream {
        streams[s.kind] = s
        if s.writable { s.tasks.append(Task { [weak self] in await self?.runWriter(s) }) }
        if s.readable { s.tasks.append(Task { [weak self] in await self?.runReader(s) }) }
        if s.kind == .control { controlReady.complete(.success(s.inbox)) }
        return s
    }

    private func remove(_ s: Stream) {
        guard streams[s.kind] === s else { return }
        streams[s.kind] = nil
        s.inbox.finish()
        s.wake.finish()
        for t in s.tasks { t.cancel() }
    }

    private func nextFrame(_ s: Stream) -> Data? { s.queue.next() }

    private func runWriter(_ s: Stream) async {
        for await _ in s.wakeups {
            while let frame = nextFrame(s) {
                do { try await s.wire.write(frame) } catch {
                    fail(.transport("write failed"), notify: false)
                    return
                }
            }
            if s.closing {
                await s.wire.finish()
                s.drained.complete(.success(()))
                return
            }
        }
    }

    // MARK: Receiving

    private func accept(_ ws: any LinkWireStream) {
        guard !closed else { ws.abort(); return }
        let kind = ws.kind
        // The peer may only open the kinds that are its to open, once each.
        guard kind.openedByClient == (role == .helper), streams[kind] == nil else {
            ws.abort()
            fail(.protocolViolation("unexpected stream \(kind)"))
            return
        }
        if case .window = kind {
            let windows = streams.keys.filter { if case .window = $0 { true } else { false } }.count
            guard windows < Self.maxIncomingWindowStreams else {
                ws.abort()
                fail(.protocolViolation("too many window streams"))
                return
            }
        }
        let s = register(Stream(kind: kind, wire: ws, openedByUs: false))
        eventsCont.yield(.streamOpened(kind, s.inbox))
    }

    private func runReader(_ s: Stream) async {
        var decoder = LinkFrameDecoder()
        do {
            while let bytes = try await s.wire.read() {
                for message in try decoder.feed(bytes) {
                    guard await received(message, on: s) else { return }
                }
            }
        } catch let error as LinkError {
            fail(error.asSessionError)
            return
        } catch {
            if !closed { fail(.transport("read failed"), notify: false) }
            return
        }
        // Clean end of the peer's writing side.
        if s.kind == .control {
            if !closed { fail(.transport("peer closed the control stream"), notify: false) }
            return
        }
        s.inbox.finish()
        eventsCont.yield(.streamFinished(s.kind))
        if !s.writable { remove(s) }
    }

    /// Returns false when the channel failed and the reader must stop.
    private func received(_ message: LinkMessage, on s: Stream) async -> Bool {
        guard !closed, !terminating else { return false }
        guard LinkMessageRules.isAllowed(message, on: s.kind, peerIsClient: role == .helper) else {
            fail(.protocolViolation("\(message.type) not allowed on \(s.kind)"))
            return false
        }
        if established, Self.isHandshakeMessage(message.type) {
            fail(.protocolViolation("\(message.type) after the handshake"))
            return false
        }
        switch message {
        case .ping(let t) where established:  // before the handshake ends a ping is a violation, left to the state machine
            if let control = streams[.control], control.writable, let frame = try? LinkFrameEncoder.encode(.pong(timestampMicros: t)) {
                _ = try? control.queue.enqueue(.pong(timestampMicros: t), encoded: frame)
                control.wake.yield()
            }
            return true
        case .close(let code, _):
            fail(.fromPeerClose(code), notify: false)
            return false
        default:
            await s.inbox.push(message, cost: Self.cost(of: message))
            return !closed
        }
    }

    private static func isHandshakeMessage(_ type: LinkMessageType) -> Bool {
        switch type {
        case .hello, .welcome, .resume, .approvalRequired, .pairProve, .pairChallenge, .pairOK, .pairDenied, .sasCommit, .sasReveal, .sasConfirm: true
        default: false
        }
    }

    private static func cost(of message: LinkMessage) -> Int {
        switch message {
        case .videoFrame(let f): f.data.count + 64
        case .surfaceSnapshot(let s): s.data.count + 64
        case .clipboardData(_, let d): d.count + 64
        case .fileChunk(let c): c.data.count + 64
        case .appsIconData(_, let png): png.count + 64
        case .cursorShape(let c): c.png.count + 64
        case .audioPacket(let a): a.data.count + 64
        default: 512
        }
    }

    // MARK: Closing

    /// Graceful close: sends `close`, lets the control queue drain, then drops the connection.
    func close(code: LinkCloseCode = .normal, reason: String = "") async {
        await terminate(.closed, closeCode: code, reason: reason, notify: true, clean: true)
    }

    /// Ends the channel with `error` after what is queued on the control stream has been written (a `pair.denied` must not be
    /// lost to our own cancel). `notify`: also send `close` with `closeCode`.
    func terminate(
        _ error: LinkSessionError, closeCode: LinkCloseCode? = nil, reason: String = "", notify: Bool, clean: Bool = false
    ) async {
        guard !closed else { return }
        terminating = true
        if let control = streams[.control], control.writable, !control.closing {
            var queued = true
            if notify {
                let message = LinkMessage.close(
                    code: closeCode ?? error.closeCode, reason: String(decoding: reason.utf8.prefix(LinkLimits.maxReasonBytes), as: UTF8.self))
                if let frame = try? LinkFrameEncoder.encode(message) { queued = (try? control.queue.enqueue(message, encoded: frame)) != nil }
            }
            if queued {
                control.closing = true
                control.wake.yield()
                _ = await withTimeout(.seconds(2)) { _ = try? await control.drained.wait() }
                // The peer closes on receipt; give that a moment so the last frame is not lost to our own cancel.
                _ = await withTimeout(.milliseconds(150)) { await self.waitUntilClosed() }
            }
        }
        fail(error, notify: false, clean: clean)
    }

    /// Ends the channel after a failure. `notify`: try to tell the peer why first.
    func fail(_ error: LinkSessionError, notify: Bool = true, clean: Bool = false) {
        guard !closed else { return }
        closed = true
        failure = error
        if notify, let control = streams[.control], control.writable {
            // Best effort and short: a hostile or stalled peer must not hold us.
            let code = error.closeCode
            let ws = control.wire
            if let frame = try? LinkFrameEncoder.encode(.close(code: code, reason: "")) {
                Task.detached { _ = await withTimeout(.milliseconds(200)) { try? await ws.write(frame) } }
            }
        }
        let all = Array(streams.values)
        streams = [:]
        for s in all {
            // The Mac never acts on what an iPad queued before the session ended (revoke, close, error). The iPad still drains
            // its inboxes: its last messages (`pair.denied`, `close`) explain why the connection ended.
            if role == .helper && established { s.inbox.discardBufferedAndFinish() } else { s.inbox.finish() }
            s.wake.finish()
            s.drained.complete(.success(()))
            for t in s.tasks { t.cancel() }
        }
        controlReady.complete(.failure(error))
        closedGate.complete(.success(()))
        acceptTask?.cancel()
        watchTask?.cancel()
        eventsCont.yield(.closed(clean ? nil : error))
        eventsCont.finish()
        // Give a best-effort close frame a moment to leave before the connection goes.
        let wire = self.wire
        Task.detached {
            if notify { _ = await sleepUnlessCancelled(.milliseconds(250)) }
            wire.close()
        }
    }
}
