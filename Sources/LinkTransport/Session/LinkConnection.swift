import Foundation
import LinkProtocol
import Network

/// Where a helper listens.
public struct LinkEndpoint: Sendable, Equatable {
    public var host: String
    public var port: UInt16
    /// Port of the TCP+TLS fallback when it differs from `port` (the helper uses the same number by default).
    public var tcpPort: UInt16?

    public init(host: String, port: UInt16, tcpPort: UInt16? = nil) {
        self.host = host; self.port = port; self.tcpPort = tcpPort
    }

    var quic: NWEndpoint { .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port) ?? .any) }
    var tcp: NWEndpoint { .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: tcpPort ?? port) ?? .any) }
}

public enum LinkTransportPreference: Sendable, Equatable {
    case quic
    case tcp
    /// QUIC first; TCP+TLS when QUIC does not come up within `quicTimeout` (for networks that block UDP). A pin mismatch
    /// never falls back: the fallback carries the same mutual TLS, so it would fail the same way.
    case automatic
}

public struct LinkClientConfiguration: Sendable {
    /// This iPad's identity (see `IdentityStore.secIdentity`).
    public var identity: LinkSecIdentity
    public var deviceName: String
    public var capabilities: LinkCapabilities
    public var sceneLimits: LinkSceneLimits
    public var mode: LinkClientMode
    /// The SPKI hash of the paired Mac; required for `.reconnect`. QR pairing takes it from the code.
    public var pinnedMacSPKIHash: Data?
    public var transport: LinkTransportPreference
    public var quicTimeout: Duration
    public var connectTimeout: Duration
    /// Called with the six digits in SAS pairing. Show them and return the user's local answer: whether they saw the same
    /// digits on the Mac. The digits are only displayed and compared by people; nothing sent to the Mac depends on them.
    /// Without a closure (or when it returns `false`) the pairing is cancelled.
    public var sasConfirmation: (@Sendable (String) async -> Bool)?
    /// After a successful pairing the Mac is stored here under `computerID`.
    public var pairedMacStore: (any PairedMacStore)?
    public var computerID: String?

    public init(
        identity: LinkSecIdentity, deviceName: String, capabilities: LinkCapabilities, sceneLimits: LinkSceneLimits,
        mode: LinkClientMode, pinnedMacSPKIHash: Data? = nil, transport: LinkTransportPreference = .automatic,
        quicTimeout: Duration = .seconds(3), connectTimeout: Duration = .seconds(10),
        sasConfirmation: (@Sendable (String) async -> Bool)? = nil,
        pairedMacStore: (any PairedMacStore)? = nil, computerID: String? = nil
    ) {
        self.identity = identity; self.deviceName = deviceName; self.capabilities = capabilities; self.sceneLimits = sceneLimits
        self.mode = mode; self.pinnedMacSPKIHash = pinnedMacSPKIHash; self.transport = transport
        self.quicTimeout = quicTimeout; self.connectTimeout = connectTimeout; self.sasConfirmation = sasConfirmation
        self.pairedMacStore = pairedMacStore; self.computerID = computerID
    }
}

/// The iPad's side of an established link session. Create it with `connect`.
public actor LinkConnection {
    public nonisolated let session: LinkSessionInfo
    public nonisolated let transport: LinkTransportKind
    /// SPKI hash of the Mac's certificate as presented in this connection.
    public nonisolated let macSPKIHash: Data
    /// Set when this connection paired the iPad with the Mac.
    public nonisolated let newlyPairedMac: PairedMac?
    /// Messages from the Mac on the control stream after the handshake (snapshot, window and app updates, pongs...).
    public nonisolated let controlMessages: LinkInbox<LinkMessage>
    /// Stream opened/finished, video back pressure, close.
    public nonisolated let events: AsyncStream<LinkEvent>

    let channel: LinkChannel

    init(
        channel: LinkChannel, session: LinkSessionInfo, transport: LinkTransportKind, macSPKIHash: Data, newlyPairedMac: PairedMac?,
        controlMessages: LinkInbox<LinkMessage>, events: AsyncStream<LinkEvent>
    ) {
        self.channel = channel; self.session = session; self.transport = transport; self.macSPKIHash = macSPKIHash
        self.newlyPairedMac = newlyPairedMac; self.controlMessages = controlMessages; self.events = events
    }

    /// Sends `message` on the stream it belongs to (input on the input stream, everything else on control, ...).
    /// Throws `queueFull` when that stream's bounded queue is full.
    public func send(_ message: LinkMessage) async throws { try await channel.send(message) }

    /// Messages of a stream the Mac opened (a window's video stream, audio), from `LinkEvent.streamOpened`.
    public func inbox(for kind: LinkStreamKind) async -> LinkInbox<LinkMessage>? { await channel.inbox(for: kind) }

    /// Sends `close`, flushes, and drops the connection.
    public func close(code: LinkCloseCode = .normal, reason: String = "") async { await channel.close(code: code, reason: reason) }

    /// Completes when the connection is gone.
    public func waitUntilClosed() async { await channel.waitUntilClosed() }

    /// Why the connection ended, once it has.
    public var failure: LinkSessionError? { get async { await channel.failure } }

    // MARK: Connecting

    /// Connects, authenticates and runs the handshake (reconnect, resume, or pairing). Throws `LinkSessionError`.
    public static func connect(to endpoint: LinkEndpoint, configuration: LinkClientConfiguration) async throws -> LinkConnection {
        let ownCertificate: LinkCertificate
        do { ownCertificate = try configuration.identity.certificate() } catch { throw LinkSessionError.transport("identity") }

        let policy: PinPolicy
        switch configuration.mode {
        case .reconnect:
            guard let pin = configuration.pinnedMacSPKIHash, pin.count == 32 else {
                throw LinkSessionError.pairingFailed("no pinned Mac for reconnect")
            }
            policy = .pinned(pin)
        case .pairWithQR(let payload): policy = .pinned(payload.macSPKIHash)
        case .pairWithSAS: policy = .pairing
        }

        let wire = try await makeWire(to: endpoint, configuration: configuration, policy: policy)
        let channel = LinkChannel(wire: wire, role: .client)
        await channel.start()
        do {
            return try await handshake(channel: channel, wire: wire, ownSPKIHash: ownCertificate.spkiHash, configuration: configuration)
        } catch {
            let mapped = (error as? LinkSessionError) ?? .transport("handshake")
            await channel.terminate(mapped, notify: false)
            throw mapped
        }
    }

    private static func makeWire(
        to endpoint: LinkEndpoint, configuration: LinkClientConfiguration, policy: PinPolicy
    ) async throws -> any LinkWire {
        func quic() async throws -> any LinkWire {
            let wire = QUICWire(endpoint: endpoint.quic, identity: configuration.identity, policy: policy)
            try await wire.start(timeout: configuration.transport == .automatic ? configuration.quicTimeout : configuration.connectTimeout)
            return wire
        }
        func tcp() async throws -> any LinkWire {
            let wire = TCPMuxWire(endpoint: endpoint.tcp, identity: configuration.identity, policy: policy)
            try await wire.start(timeout: configuration.connectTimeout)
            return wire
        }
        func mapped(_ error: Error) -> LinkSessionError {
            switch error as? LinkWireError {
            case .pinMismatch: .pinMismatch
            case .timedOut: .timeout
            default: .transport("connection failed")
            }
        }
        switch configuration.transport {
        case .quic:
            do { return try await quic() } catch { throw mapped(error) }
        case .tcp:
            do { return try await tcp() } catch { throw mapped(error) }
        case .automatic:
            do { return try await quic() } catch let error as LinkWireError where error == .pinMismatch {
                throw LinkSessionError.pinMismatch
            } catch {
                do { return try await tcp() } catch { throw mapped(error) }
            }
        }
    }

    private static func handshake(
        channel: LinkChannel, wire: any LinkWire, ownSPKIHash: Data, configuration: LinkClientConfiguration
    ) async throws -> LinkConnection {
        let peer = wire.peer
        let hello = LinkHello(
            protocolMin: LinkProtocolVersion.supported.lowerBound, protocolMax: LinkProtocolVersion.supported.upperBound,
            capabilities: configuration.capabilities, deviceName: configuration.deviceName, sceneLimits: configuration.sceneLimits)
        var machine = ClientSessionMachine(
            hello: hello, mode: configuration.mode, ownSPKIHash: ownSPKIHash, peerSPKIHash: peer.spkiHash, exporter: peer.exporter)
        var pairedMac: PairedMac?
        var ready: LinkSessionInfo?
        let deadline = DeadlineTimer { await channel.fail(.timeout, notify: true) }
        defer { deadline.cancel() }

        func perform(_ actions: [ClientSessionMachine.Action]) async throws {
            for action in actions {
                switch action {
                case .send(let m): try await channel.send(m)
                case .terminate(let error, let notify):
                    await channel.terminate(error, notify: notify)
                    throw error
                case .event(.ready(let info)): ready = info
                case .event(.paired(let macName, _)):
                    let mac = PairedMac(
                        computerID: configuration.computerID ?? "", spkiHash: peer.spkiHash, name: macName, pairedAt: Date())
                    pairedMac = mac
                    if configuration.computerID != nil { try? configuration.pairedMacStore?.save(mac) }
                case .event(.awaitingMacApproval): break
                case .event(.sasCode(let code)):
                    deadline.disarm()
                    let confirmed = await configuration.sasConfirmation?(code) ?? false
                    let next = machine.sasDecision(confirmed: confirmed)
                    deadline.arm(machine.phaseTimeout == nil ? nil : step)
                    try await perform(next)
                }
            }
        }

        let step = configuration.connectTimeout.seconds
        deadline.arm(step)
        try await perform(machine.start())
        let inbox = try await channel.controlInbox()
        deadline.arm(machine.phaseTimeout == nil ? nil : step)
        for await message in inbox {
            let actions = machine.receive(message)
            deadline.arm(machine.phaseTimeout == nil ? nil : step)
            try await perform(actions)
            if ready != nil { break }
        }
        guard let info = ready else { throw (await channel.failure) ?? LinkSessionError.closed }
        deadline.cancel()
        await channel.markEstablished()
        // Open the input stream now so the Mac can read it from the first event on.
        try? await channel.openInputStream()
        return LinkConnection(
            channel: channel, session: info, transport: wire.transport, macSPKIHash: peer.spkiHash, newlyPairedMac: pairedMac,
            controlMessages: inbox, events: channel.events)
    }
}

/// A restartable one-shot timer for handshake phases.
final class DeadlineTimer: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private let onExpire: @Sendable () async -> Void

    init(onExpire: @escaping @Sendable () async -> Void) { self.onExpire = onExpire }

    func arm(_ seconds: TimeInterval?) {
        let t = seconds.map { s in
            Task { [onExpire] in
                if await sleepUnlessCancelled(.milliseconds(Int(s * 1000))) { await onExpire() }
            }
        }
        lock.withLock { task?.cancel(); task = t }
    }

    func disarm() { arm(nil) }
    func cancel() { arm(nil) }
}
