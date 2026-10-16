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
    /// Handshakes in progress that one remote address may hold at once, so a single host on the network cannot fill every slot.
    public var maxPendingPerSource: Int
    public var maxSessions: Int

    public init(
        identity: LinkSecIdentity, macName: String, capabilities: LinkCapabilities, pairedDevices: any PairedDeviceStore,
        approvalHandler: @escaping @Sendable (PairingApprovalRequest) async -> Bool,
        displays: @escaping @Sendable () -> [LinkDisplayInfo] = { [] },
        approvalTimeout: Duration = .seconds(120), handshakeTimeout: Duration = .seconds(10),
        snapshotProvider: (@Sendable (HelperSessionReady) async -> LinkSnapshot?)? = nil,
        askBeforeEachSession: @escaping @Sendable () -> Bool = { false },
        port: UInt16 = 0, enableQUIC: Bool = true, enableTCP: Bool = true, loopbackOnly: Bool = false,
        advertiseBonjour: Bool = false, maxPendingConnections: Int = 8, maxPendingPerSource: Int = 3, maxSessions: Int = 4
    ) {
        self.identity = identity; self.macName = macName; self.capabilities = capabilities; self.pairedDevices = pairedDevices
        self.approvalHandler = approvalHandler; self.displays = displays; self.approvalTimeout = approvalTimeout
        self.handshakeTimeout = handshakeTimeout
        self.snapshotProvider = snapshotProvider; self.askBeforeEachSession = askBeforeEachSession
        self.port = port; self.enableQUIC = enableQUIC; self.enableTCP = enableTCP
        self.loopbackOnly = loopbackOnly; self.advertiseBonjour = advertiseBonjour
        self.maxPendingConnections = maxPendingConnections; self.maxPendingPerSource = maxPendingPerSource
        self.maxSessions = maxSessions
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
    /// Handshakes in progress per remote address (addresses that are not yet known are not counted).
    private var pendingBySource: [String: Int] = [:]
    private var live: [UInt64: LinkServerConnection] = [:]
    /// Handshakes in progress. Each is cancelled by `revoke`, `disconnectAll` or `stop`, and admission is decided against this
    /// table in `commitHandshake` and `register`, which run to completion without suspending.
    private struct Handshake { let channel: LinkChannel; let spki: Data; var cancelled = false; var pairingApproval = false }
    private var handshakes: [UInt64: Handshake] = [:]
    private var nextHandshakeID: UInt64 = 0
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
        // Nothing started before the stop may finish pairing after it: offers, window, claim and pending approvals all go.
        pairingAdmission.reset()
        pairingLedger.revokeAll()
        let waiting = cancelHandshakes { _ in true }
        for c in all { await c.close(code: .helperShuttingDown) }
        for ch in waiting { await ch.close(code: .helperShuttingDown) }
        connectionsCont.finish()
    }

    /// Lets an unknown iPad start SAS pairing ("Pair without camera") for `duration` seconds. It closes by itself, after one
    /// device paired, and after one denial on the Mac. While it is closed SAS sessions are refused. QR pairing has no window:
    /// see `makePairingQRPayload`. Showing a QR code never enables SAS.
    public func openPairingWindow(method: PairingWindowMethod = .sas, duration: TimeInterval = PairingAdmission.defaultWindow) {
        pairingAdmission.open(duration: duration)
    }

    /// Cancels pairing: closes the SAS window, burns the QR offers on screen, drops the in-flight pairing claim and cancels
    /// every pairing approval that is still waiting for the Mac user (its answer is ignored; the approval handler's task is
    /// cancelled and the iPad is disconnected).
    public func closePairingWindow(method: PairingWindowMethod = .sas) async {
        pairingAdmission.reset()
        pairingLedger.revokeAll()
        for ch in cancelHandshakes({ $0.pairingApproval }) { await ch.close(code: .normal, reason: "pairing closed") }
    }

    /// A handshake is about to ask the Mac user to approve a new pairing.
    func beginPairingApproval(_ id: UInt64) { handshakes[id]?.pairingApproval = true }

    public func isPairingWindowOpen(method: PairingWindowMethod = .sas) -> Bool { pairingAdmission.isOpen }

    /// Issues a pairing secret and returns the QR payload for it (`hostHints`: addresses or names the iPad may try).
    /// The offer itself is the admission: only a `pair.prove` naming its nonce is considered, for `PairingSecretLedger.lifetime`
    /// or until a pairing succeeds. It does not enable SAS pairing.
    public func makePairingQRPayload(hostHints: [String]) throws -> PairingQRPayload {
        let offer = try pairingLedger.issue()
        return PairingQRPayload(
            hostHints: hostHints, port: endpoint.port, macSPKIHash: helperSPKIHash, secret: offer.secret, nonce: offer.nonce,
            expiry: offer.expiry)
    }

    /// Removes the pairing and disconnects the device if it is connected.
    ///
    /// Everything up to the first suspension runs as one step of this actor, so no handshake can be admitted in between:
    /// the store entry goes, the device's resume tokens are invalidated, every handshake of that identity (including one that
    /// is waiting for the Mac user's approval) is cancelled and can no longer be admitted, and then all its live
    /// connections and handshakes are closed. If the store throws, the connections are still closed (fail safe) and the
    /// error is rethrown.
    @discardableResult public func revoke(deviceSPKIHash: Data) async throws -> Bool {
        resumeTokens.invalidate(identityHash: deviceSPKIHash)
        let waiting = cancelHandshakes { $0.spki == deviceSPKIHash }
        let connections = live.values.filter { $0.deviceSPKIHash == deviceSPKIHash }
        var removed = false
        var failure: Error?
        do { removed = try configuration.pairedDevices.revoke(spkiHash: deviceSPKIHash) } catch { failure = error }
        for ch in waiting { await ch.close(code: .notAuthorized, reason: "revoked") }
        for c in connections { await c.close(code: .notAuthorized, reason: "revoked") }
        if let failure { throw failure }
        return removed
    }

    /// Closes every session and every handshake in progress (the "Disconnect all" menu item). A device waiting for approval
    /// is not admitted afterwards.
    public func disconnectAll(code: LinkCloseCode = .normal) async {
        let waiting = cancelHandshakes { _ in true }
        for ch in waiting { await ch.close(code: code) }
        for c in Array(live.values) { await c.close(code: code) }
    }

    /// Marks matching handshakes cancelled and returns their channels. Synchronous.
    private func cancelHandshakes(_ matching: (Handshake) -> Bool) -> [LinkChannel] {
        var channels: [LinkChannel] = []
        for (id, h) in handshakes where matching(h) {
            handshakes[id]?.cancelled = true
            channels.append(h.channel)
        }
        return channels
    }

    /// Called by a handshake when it is about to send `welcome`: decides, atomically with the paired-device store, whether the
    /// device is admitted. Not admitted when the handshake was cancelled, the server stopped, or the device is not (or no
    /// longer) paired.
    func commitHandshake(_ id: UInt64, _ commit: HandshakeCommit) -> CommitResult {
        guard running, let h = handshakes[id], !h.cancelled else { return .notAuthorized }
        return commit.apply(
            peerSPKIHash: h.spki, devices: configuration.pairedDevices, admission: pairingAdmission, ledger: pairingLedger,
            resumeTokens: resumeTokens)
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
        var slotSource = wire.remoteAddress
        guard claimSourceSlot(slotSource) else { wire.close(); return }
        pending += 1
        defer { pending -= 1; releaseSourceSlot(slotSource) }
        do {
            try await wire.start(timeout: .seconds(10))
            // QUIC learns the remote address only once the connection is up: count it against that address from now on.
            let known = wire.remoteAddress
            if known != slotSource {
                releaseSourceSlot(slotSource)
                slotSource = LinkRemoteAddress.unknown  // nothing to give back if the new address is refused
                guard claimSourceSlot(known) else { wire.close(); return }
                slotSource = known
            }
            let channel = LinkChannel(wire: wire, role: .helper)
            await channel.start()
            guard running else { await channel.fail(.helperShuttingDown, notify: false); return }
            let handshakeID = nextHandshakeID
            nextHandshakeID += 1
            handshakes[handshakeID] = Handshake(channel: channel, spki: wire.peer.spkiHash)
            defer { handshakes[handshakeID] = nil }
            let dependencies = LinkServerConnection.Dependencies(
                configuration: configuration, ledger: pairingLedger, resumeTokens: resumeTokens, helperSPKIHash: helperSPKIHash,
                admission: pairingAdmission, source: wire.remoteAddress, server: self, handshakeID: handshakeID)
            let connection: LinkServerConnection
            do {
                connection = try await LinkServerConnection.establish(channel: channel, wire: wire, dependencies: dependencies)
            } catch {
                await channel.fail((error as? LinkSessionError) ?? .transport("handshake"), notify: false)
                return
            }
            await register(connection, handshake: handshakeID)
        } catch {
            wire.close()
        }
    }

    private func claimSourceSlot(_ source: String) -> Bool {
        guard source != LinkRemoteAddress.unknown else { return true }
        let count = pendingBySource[source, default: 0]
        guard count < configuration.maxPendingPerSource else { return false }
        pendingBySource[source] = count + 1
        return true
    }

    private func releaseSourceSlot(_ source: String) {
        guard source != LinkRemoteAddress.unknown, let count = pendingBySource[source] else { return }
        pendingBySource[source] = count > 1 ? count - 1 : nil
    }

    private func register(_ connection: LinkServerConnection, handshake: UInt64) async {
        // Last check, in the same step as the insert below: a revoke, disconnect or stop since `welcome` wins.
        guard running, let h = handshakes[handshake], !h.cancelled,
              configuration.pairedDevices.device(spkiHash: connection.deviceSPKIHash) != nil
        else {
            await connection.close(code: .notAuthorized, reason: "revoked")
            return
        }
        handshakes[handshake] = nil
        let id = connection.session.sessionID
        // Everything up to the insert is one step (no suspension), so a revoke sees this connection in `live` from the moment
        // it stops being a handshake. A new session from the same device replaces the old one.
        var replaced: [LinkServerConnection] = []
        for (key, old) in live where old.deviceSPKIHash == connection.deviceSPKIHash {
            live[key] = nil
            replaced.append(old)
        }
        let full = live.count >= configuration.maxSessions
        if !full {
            live[id] = connection
            connectionsCont.yield(connection)
        }
        for old in replaced { await old.close(code: .sessionReplaced, reason: "replaced") }
        guard !full else {
            await connection.close(code: .internalError, reason: "too many sessions")
            return
        }
        Task { [weak self] in
            await connection.waitUntilClosed()
            await self?.forget(id)
        }
    }

    private func forget(_ id: UInt64) { live[id] = nil }
}
