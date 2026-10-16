import Foundation
import LinkProtocol
import Network

public struct LinkServerConfiguration: Sendable {
    /// The helper's identity.
    public var identity: LinkSecIdentity
    /// Shown on the iPad.
    public var macName: String
    public var capabilities: LinkCapabilities
    public var displays: @Sendable () -> [LinkDisplayInfo]
    public var pairedDevices: any PairedDeviceStore
    /// Local approval (LocalAuthentication on the Mac) for a new pairing, and for each session when
    /// `askBeforeEachSession` is on. Injected: this package has no UI. Return `true` to approve. Not called at all for a
    /// paired device when `askBeforeEachSession` is off.
    ///
    /// For SAS pairing the request carries `sasCode`: show those six digits and the device name, let the person compare them
    /// with the iPad, and return their local yes/no. Matching and approving both happen here, on the Mac.
    public var approvalHandler: @Sendable (PairingApprovalRequest) async -> Bool
    public var approvalTimeout: Duration
    /// How long each handshake step may take before the connection is dropped (not counting the person at the Mac).
    public var handshakeTimeout: Duration
    /// Sent right after `welcome` (and after a resume) so the iPad starts from a complete state.
    public var snapshotProvider: (@Sendable (HelperSessionReady) async -> LinkSnapshot?)?
    public var askBeforeEachSession: @Sendable () -> Bool
    /// 0 picks a free port (QUIC and TCP share the number when possible).
    public var port: UInt16
    public var enableQUIC: Bool
    public var enableTCP: Bool
    /// Bind to loopback only (tests, the mock helper).
    public var loopbackOnly: Bool
    /// Advertise `_screon-link._udp` over Bonjour.
    public var advertiseBonjour: Bool
    public var maxPendingConnections: Int
    public var maxSessions: Int

    public init(
        identity: LinkSecIdentity, macName: String, capabilities: LinkCapabilities, pairedDevices: any PairedDeviceStore,
        approvalHandler: @escaping @Sendable (PairingApprovalRequest) async -> Bool,
        displays: @escaping @Sendable () -> [LinkDisplayInfo] = { [] },
        approvalTimeout: Duration = .seconds(120), handshakeTimeout: Duration = .seconds(10),
        snapshotProvider: (@Sendable (HelperSessionReady) async -> LinkSnapshot?)? = nil,
        askBeforeEachSession: @escaping @Sendable () -> Bool = { false },
        port: UInt16 = 0, enableQUIC: Bool = true, enableTCP: Bool = true, loopbackOnly: Bool = false,
        advertiseBonjour: Bool = false, maxPendingConnections: Int = 8, maxSessions: Int = 4
    ) {
        self.identity = identity; self.macName = macName; self.capabilities = capabilities; self.pairedDevices = pairedDevices
        self.approvalHandler = approvalHandler; self.displays = displays; self.approvalTimeout = approvalTimeout
        self.handshakeTimeout = handshakeTimeout
        self.snapshotProvider = snapshotProvider; self.askBeforeEachSession = askBeforeEachSession
        self.port = port; self.enableQUIC = enableQUIC; self.enableTCP = enableTCP
        self.loopbackOnly = loopbackOnly; self.advertiseBonjour = advertiseBonjour
        self.maxPendingConnections = maxPendingConnections; self.maxSessions = maxSessions
    }
}

public struct LinkServerEndpoint: Sendable, Equatable {
    public var quicPort: UInt16?
    public var tcpPort: UInt16?
    /// The port to put in a pairing QR code.
    public var port: UInt16 { quicPort ?? tcpPort ?? 0 }
}

/// The helper's listener: accepts QUIC and TCP+TLS connections, runs the handshake (reconnect, resume, pairing) and hands
/// out established `LinkServerConnection`s.
///
/// Every TLS client with a well-formed certificate may connect; what it can do is decided by the handshake. An unknown
/// device reaches the pairing state machine and nothing else. Handshakes are limited in number and in time.
public actor LinkServer {
    public nonisolated let pairingLedger: PairingSecretLedger
    public nonisolated let resumeTokens: ResumeTokenStore
    /// The pairing window and the SAS rate limits (see `openPairingWindow`).
    public nonisolated let pairingAdmission: PairingAdmission
    /// Established sessions, after the handshake.
    public nonisolated let connections: AsyncStream<LinkServerConnection>
    public nonisolated let helperSPKIHash: Data

    private let configuration: LinkServerConfiguration
    private let connectionsCont: AsyncStream<LinkServerConnection>.Continuation
    private let queue = DispatchQueue(label: "screon.link.server")
    private let recorder = PeerVerifyRecorder()
    private var quicListener: NWListener?
    private var tcpListener: NWListener?
    private var pending = 0
    private var live: [UInt64: LinkServerConnection] = [:]
    private var running = false
    private var endpoint = LinkServerEndpoint()

    public init(
        configuration: LinkServerConfiguration, ledger: PairingSecretLedger = PairingSecretLedger(),
        resumeTokens: ResumeTokenStore = ResumeTokenStore(), admission: PairingAdmission = PairingAdmission()
    ) throws {
        self.configuration = configuration
        pairingLedger = ledger
        pairingAdmission = admission
        self.resumeTokens = resumeTokens
        helperSPKIHash = try configuration.identity.certificate().spkiHash
        (connections, connectionsCont) = AsyncStream<LinkServerConnection>.makeStream(bufferingPolicy: .bufferingOldest(16))
    }

    public var activeSessions: [HelperSessionReady] { live.values.map(\.session) }

    // MARK: Lifecycle

    public func start() async throws -> LinkServerEndpoint {
        guard !running else { return endpoint }
        guard configuration.enableQUIC || configuration.enableTCP else { throw LinkSessionError.transport("no transport enabled") }
        var attempt = 0
        while true {
            attempt += 1
            do {
                var result = LinkServerEndpoint()
                var requested = configuration.port
                if configuration.enableQUIC {
                    let listener = try makeQUICListener(port: requested)
                    let port = try await Self.waitReady(listener, queue: queue)
                    quicListener = listener
                    result.quicPort = port
                    requested = port
                }
                if configuration.enableTCP {
                    let listener = try makeTCPListener(port: requested)
                    let port = try await Self.waitReady(listener, queue: queue)
                    tcpListener = listener
                    result.tcpPort = port
                }
                endpoint = result
                running = true
                return result
            } catch {
                quicListener?.cancel(); tcpListener?.cancel()
                quicListener = nil; tcpListener = nil
                // The UDP port we got may be taken for TCP; try another pair.
                if configuration.port == 0, attempt < 5 { continue }
                throw LinkSessionError.transport("cannot listen")
            }
        }
    }

    public func stop() async {
        running = false
        quicListener?.cancel(); tcpListener?.cancel()
        quicListener = nil; tcpListener = nil
        let all = Array(live.values)
        live = [:]
        for c in all { await c.close(code: .helperShuttingDown) }
        connectionsCont.finish()
    }

    /// Lets an unknown iPad start pairing (QR or SAS) for `duration` seconds. Call it when the person at the Mac asks to pair
    /// a device ("Pair new iPad", "Pair without camera"). It closes by itself, and right after one device paired. While it is
    /// closed, unknown devices are refused before any proof is looked at.
    public func openPairingWindow(duration: TimeInterval = PairingAdmission.defaultWindow) {
        pairingAdmission.open(duration: duration)
    }

    public func closePairingWindow() { pairingAdmission.close() }

    public var isPairingWindowOpen: Bool { pairingAdmission.isOpen }

    /// Issues a pairing secret and returns the QR payload for it (`hostHints`: addresses or names the iPad may try).
    /// Showing the QR code opens the pairing window for as long as the code is valid.
    public func makePairingQRPayload(hostHints: [String]) throws -> PairingQRPayload {
        let offer = try pairingLedger.issue()
        pairingAdmission.open(duration: PairingSecretLedger.lifetime)
        return PairingQRPayload(
            hostHints: hostHints, port: endpoint.port, macSPKIHash: helperSPKIHash, secret: offer.secret, nonce: offer.nonce,
            expiry: offer.expiry)
    }

    /// Removes the pairing and disconnects the device if it is connected.
    @discardableResult public func revoke(deviceSPKIHash: Data) async throws -> Bool {
        let removed = try configuration.pairedDevices.revoke(spkiHash: deviceSPKIHash)
        for c in live.values where c.deviceSPKIHash == deviceSPKIHash { await c.close(code: .notAuthorized, reason: "revoked") }
        return removed
    }

    /// Closes every session (the "Disconnect all" menu item).
    public func disconnectAll(code: LinkCloseCode = .normal) async {
        for c in Array(live.values) { await c.close(code: code) }
    }

    // MARK: Listeners

    private func makeQUICListener(port: UInt16) throws -> NWListener {
        let params = QUICWire.parameters(identity: configuration.identity, policy: .pairing, recorder: recorder, queue: queue)
        if configuration.loopbackOnly { params.requiredInterfaceType = .loopback }
        let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port) ?? .any)
        if configuration.advertiseBonjour {
            listener.service = NWListener.Service(
                name: nil, type: LinkTransportInfo.bonjourServiceType, domain: nil,
                txtRecord: LinkBonjour.txtRecord(spkiHash: helperSPKIHash))
        }
        listener.newConnectionGroupHandler = { [weak self] group in
            guard let self else { group.cancel(); return }
            let wire = QUICWire(group: group, queue: self.queue, recorder: self.recorder)
            Task { await self.accept(wire) }
        }
        return listener
    }

    private func makeTCPListener(port: UInt16) throws -> NWListener {
        let params = TCPMuxWire.parameters(identity: configuration.identity, policy: .pairing, recorder: recorder, queue: queue)
        if configuration.loopbackOnly { params.requiredInterfaceType = .loopback }
        let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port) ?? .any)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            let wire = TCPMuxWire(connection: connection, queue: self.queue, recorder: self.recorder, weAreClient: false)
            Task { await self.accept(wire) }
        }
        return listener
    }

    private static func waitReady(_ listener: NWListener, queue: DispatchQueue) async throws -> UInt16 {
        let gate = OneShot<UInt16>()
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                if let p = listener.port?.rawValue { gate.complete(.success(p)) }
            case .failed(let e): gate.complete(.failure(LinkWireError.network("\(e)")))
            case .cancelled: gate.complete(.failure(LinkWireError.closed))
            default: break
            }
        }
        listener.start(queue: queue)
        let timer = Task { if await sleepUnlessCancelled(.seconds(5)) { gate.complete(.failure(LinkWireError.timedOut)) } }
        defer { timer.cancel() }
        return try await gate.wait()
    }

    // MARK: Connections

    private func accept(_ wire: any LinkWire) async {
        guard running, pending < configuration.maxPendingConnections else { wire.close(); return }
        pending += 1
        defer { pending -= 1 }
        do {
            try await wire.start(timeout: .seconds(10))
            let channel = LinkChannel(wire: wire, role: .helper)
            await channel.start()
            let dependencies = LinkServerConnection.Dependencies(
                configuration: configuration, ledger: pairingLedger, resumeTokens: resumeTokens, helperSPKIHash: helperSPKIHash,
                admission: pairingAdmission, source: wire.remoteAddress)
            let connection: LinkServerConnection
            do {
                connection = try await LinkServerConnection.establish(channel: channel, wire: wire, dependencies: dependencies)
            } catch {
                await channel.fail((error as? LinkSessionError) ?? .transport("handshake"), notify: false)
                return
            }
            await register(connection)
        } catch {
            wire.close()
        }
    }

    private func register(_ connection: LinkServerConnection) async {
        let id = connection.session.sessionID
        // A new session from the same device replaces the old one.
        for (key, old) in live where old.deviceSPKIHash == connection.deviceSPKIHash {
            live[key] = nil
            await old.close(code: .sessionReplaced, reason: "replaced")
        }
        guard live.count < configuration.maxSessions else {
            await connection.close(code: .internalError, reason: "too many sessions")
            return
        }
        live[id] = connection
        connectionsCont.yield(connection)
        Task { [weak self] in
            await connection.waitUntilClosed()
            await self?.forget(id)
        }
    }

    private func forget(_ id: UInt64) { live[id] = nil }
}
