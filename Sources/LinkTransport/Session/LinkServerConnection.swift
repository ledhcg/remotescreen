import Foundation
import LinkProtocol

/// The Mac helper's side of an established link session. `LinkServer` hands these out after the handshake succeeded.
public actor LinkServerConnection {
    public nonisolated let session: HelperSessionReady
    public nonisolated let transport: LinkTransportKind
    /// Messages from the iPad on the control stream after the handshake.
    public nonisolated let controlMessages: LinkInbox<LinkMessage>
    /// Stream opened/finished (the iPad's input stream arrives here as `.streamOpened(.input, inbox)`), video back pressure,
    /// close.
    public nonisolated let events: AsyncStream<LinkEvent>

    let channel: LinkChannel

    init(
        channel: LinkChannel, session: HelperSessionReady, transport: LinkTransportKind, controlMessages: LinkInbox<LinkMessage>,
        events: AsyncStream<LinkEvent>
    ) {
        self.channel = channel; self.session = session; self.transport = transport
        self.controlMessages = controlMessages; self.events = events
    }

    public nonisolated var deviceSPKIHash: Data { session.deviceSPKIHash }

    /// Sends `message` on the stream it belongs to. Window media (`video.*`, `surface.snapshot`, `cursor.*`) opens the
    /// window's unidirectional stream on first use. Throws `queueFull` when a control queue overflows; a video queue never
    /// throws, it drops (see `LinkEvent.videoBackpressure`).
    public func send(_ message: LinkMessage) async throws { try await channel.send(message) }

    /// Ends a window's video stream after what is queued has been written (the iPad unsubscribed or the window closed).
    public func finishWindowStream(_ window: WindowID) async { await channel.finishStream(.window(window)) }

    /// The iPad's input stream inbox, once it has opened it.
    public func inputMessages() async -> LinkInbox<LinkMessage>? { await channel.inbox(for: .input) }

    public func close(code: LinkCloseCode = .normal, reason: String = "") async { await channel.close(code: code, reason: reason) }

    public func waitUntilClosed() async { await channel.waitUntilClosed() }

    public var failure: LinkSessionError? { get async { await channel.failure } }

    // MARK: Handshake

    struct Dependencies: Sendable {
        var configuration: LinkServerConfiguration
        var ledger: PairingSecretLedger
        var resumeTokens: ResumeTokenStore
        var helperSPKIHash: Data
        var admission: PairingAdmission
        /// Normalised remote address, for rate limiting only.
        var source: String
    }

    /// Runs the helper side of the handshake on a channel whose wire is up. Throws `LinkSessionError`.
    static func establish(channel: LinkChannel, wire: any LinkWire, dependencies d: Dependencies) async throws -> LinkServerConnection {
        let config = d.configuration
        let peer = wire.peer
        var machine = HelperSessionMachine(
            configuration: HelperSessionMachine.Configuration(
                macName: config.macName, helperSPKIHash: d.helperSPKIHash, capabilities: config.capabilities,
                displays: config.displays(), askBeforeEachSession: config.askBeforeEachSession()),
            peerSPKIHash: peer.spkiHash, exporter: peer.exporter, devices: config.pairedDevices, ledger: d.ledger,
            resumeTokens: d.resumeTokens, admission: d.admission, source: d.source)
        var ready: HelperSessionReady?
        let deadline = DeadlineTimer { await channel.fail(.timeout, notify: true) }
        defer { deadline.cancel() }

        func perform(_ actions: [HelperSessionMachine.Action]) async throws {
            for action in actions {
                switch action {
                case .send(let m): try await channel.send(m)
                case .ready(let r): ready = r
                case .terminate(let error, let notify):
                    await channel.terminate(error, notify: notify)
                    throw error
                case .requestApproval(let request):
                    deadline.disarm()
                    let handler = config.approvalHandler
                    let approved = await withTimeout(config.approvalTimeout) { await handler(request) } ?? false
                    let next = machine.approvalResult(approved)
                    deadline.arm(machine.phaseTimeout == nil ? nil : step)
                    try await perform(next)
                }
            }
        }

        let step = config.handshakeTimeout.seconds
        deadline.arm(step)
        let inbox = try await channel.controlInbox()
        for await message in inbox {
            let actions = machine.receive(message)
            deadline.arm(machine.phaseTimeout == nil ? nil : step)
            try await perform(actions)
            if ready != nil { break }
        }
        guard let info = ready else { throw (await channel.failure) ?? LinkSessionError.closed }
        deadline.cancel()
        await channel.markEstablished()
        if let provider = config.snapshotProvider, let snapshot = await provider(info) {
            try await channel.send(.snapshot(snapshot))
        }
        return LinkServerConnection(channel: channel, session: info, transport: wire.transport, controlMessages: inbox, events: channel.events)
    }
}

extension Duration {
    /// Seconds as a `TimeInterval`.
    var seconds: TimeInterval { TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1e18 }
}
