import CryptoKit
import Foundation
import LinkProtocol

// Pure session state machines for the handshake of one link connection. They take decoded messages and user decisions in,
// and return actions (messages to send, events for the app, termination). No networking, no timers, no UI: the connection
// actors drive them. Handshake order, all on the control stream:
//
//   reconnect:  C: hello, resume(token | zeros)                      H: welcome (+ snapshot from the app)
//   QR pairing: C: hello, pair.prove(mac)    H: approvalRequired, [approval on the Mac] pair.ok, welcome
//   SAS pairing:C: hello, sas.commit  H: sas.commit  C: sas.reveal  H: sas.reveal
//               Both devices now DISPLAY the same six digits and the people compare them. The digits never leave a device
//               and nothing on the wire is derived from them: confirming is a local act on each side.
//               iPad user confirms:  C: sas.confirm   H: approvalRequired, [the Mac user compares and approves]  pair.ok, welcome
//   The session is bound to the TLS identities pinned in the transcript the digits were computed over.
//
// The first message after `hello` always says what the client wants, so the helper never has to guess or wait on a timer.

/// What the iPad wants from this connection.
public enum LinkClientMode: Sendable {
    /// The Mac is already paired. `credentials` resumes a session when present.
    case reconnect(LinkResumeCredentials?)
    /// First contact by QR code.
    case pairWithQR(PairingQRPayload)
    /// First contact without a camera: compare six digits on both screens.
    case pairWithSAS
}

/// What the app learns when the handshake succeeds.
public struct LinkSessionInfo: Sendable, Equatable {
    public var protocolVersion: UInt16
    /// Features both sides support.
    public var capabilities: LinkCapabilities
    public var sessionID: UInt64
    /// Single use; present it in `LinkClientMode.reconnect` after a connection loss (valid 10 minutes).
    public var resumeToken: Data
    public var macName: String
    public var displays: [LinkDisplayInfo]
}

enum SessionText {
    /// Peer-supplied device name made safe to show: no control characters, trimmed, at most `PairingProof.maxDeviceNameBytes`.
    static func sanitizedDeviceName(_ s: String) -> String {
        var out = ""
        var bytes = 0
        for scalar in s.unicodeScalars {
            if scalar.properties.generalCategory == .control || scalar.properties.generalCategory == .format
                || scalar.properties.generalCategory == .lineSeparator || scalar.properties.generalCategory == .paragraphSeparator {
                continue
            }
            let n = String(scalar).utf8.count
            guard bytes + n <= PairingProof.maxDeviceNameBytes else { break }
            out.unicodeScalars.append(scalar)
            bytes += n
        }
        let trimmed = out.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "iPad" : trimmed
    }
}

/// The SAS transcript. The six digits are shown, compared by people, and never used as a key or sent on the wire.
enum SASConfirmation {
    /// Both sides compute the code over the helper's hash first, then the iPad's.
    static func transcript(macSPKIHash: Data, ipadSPKIHash: Data) -> Data { macSPKIHash + ipadSPKIHash }
}

// MARK: - Client

struct ClientSessionMachine {
    enum Event: Equatable, Sendable {
        /// The Mac asked its user to approve this session; keep waiting.
        case awaitingMacApproval
        /// Show these six digits and ask the user whether they match the Mac.
        case sasCode(String)
        case paired(macName: String, helperID: Data)
        case ready(LinkSessionInfo)
    }

    enum Action: Equatable {
        case send(LinkMessage)
        case event(Event)
        /// End the connection. `notifyPeer`: send `close` with the error's code first.
        case terminate(LinkSessionError, notifyPeer: Bool)
    }

    private enum Phase {
        case idle, awaitingWelcome, awaitingChallenge, awaitingPairResult
        case sasAwaitPeerCommit, sasAwaitPeerReveal, sasAwaitUser, finished
    }

    let hello: LinkHello
    let mode: LinkClientMode
    let ownSPKIHash: Data
    let peerSPKIHash: Data
    let exporter: Data?

    private var phase = Phase.idle
    private var sas: SASExchange?
    private var paired = false
    private var macApproving = false

    init(hello: LinkHello, mode: LinkClientMode, ownSPKIHash: Data, peerSPKIHash: Data, exporter: Data?) {
        precondition(hello.protocolRange != nil)
        self.hello = hello
        self.mode = mode
        self.ownSPKIHash = ownSPKIHash
        self.peerSPKIHash = peerSPKIHash
        self.exporter = exporter
    }

    var isFinished: Bool { phase == .finished }

    /// How long the iPad waits for the person at the Mac (the helper's own approval timeout is shorter).
    static let macApprovalWait: TimeInterval = 150

    /// Seconds the current phase may take, or `nil` when it waits for a person.
    var phaseTimeout: TimeInterval? {
        switch phase {
        case .sasAwaitUser, .finished: nil
        case .awaitingPairResult, .awaitingWelcome: macApproving ? Self.macApprovalWait : 10
        default: 10
        }
    }

    private var pairName: String { SessionText.sanitizedDeviceName(hello.deviceName) }

    private mutating func fail(_ error: LinkSessionError, notify: Bool = true) -> [Action] {
        phase = .finished
        return [.terminate(error, notifyPeer: notify)]
    }

    mutating func start() -> [Action] {
        guard phase == .idle else { return [] }
        var actions: [Action] = [.send(.hello(hello))]
        switch mode {
        case .reconnect(let credentials):
            let token = credentials.flatMap { try? LinkBytes32($0.token) } ?? LinkBytes32(repeating: 0)
            actions.append(.send(.resume(LinkResume(resumeToken: token, lastStateVersion: credentials?.lastStateVersion ?? 0))))
            phase = .awaitingWelcome
        case .pairWithQR(let payload):
            // The QR pins the Mac. The TLS layer already enforced it; this is the belt to those braces.
            guard constantTimeEqual(payload.macSPKIHash, peerSPKIHash) else { return fail(.pinMismatch, notify: false) }
            if exporter != nil {
                actions.append(contentsOf: sendProve(payload: payload, challenge: nil))
                if phase != .finished { phase = .awaitingPairResult }
            } else {
                phase = .awaitingChallenge
            }
        case .pairWithSAS:
            let exchange = SASExchange()
            sas = exchange
            if let commit = try? LinkBytes32(exchange.commit) { actions.append(.send(.sasCommit(commit))) }
            phase = .sasAwaitPeerCommit
        }
        return actions
    }

    private mutating func sendProve(payload: PairingQRPayload, challenge: Data?) -> [Action] {
        let binding: PairingBinding
        if let exporter, challenge == nil { binding = .exporter(exporter) }
        else if let challenge { binding = .helperChallenge(nonce: payload.nonce, challenge: challenge) }
        else { return fail(.pairingFailed("no channel binding")) }
        guard let mac = try? PairingProof.mac(
            secret: payload.secret, nonce: payload.nonce, binding: binding, macSPKIHash: peerSPKIHash,
            ipadSPKIHash: ownSPKIHash, deviceName: pairName),
            let prove = try? LinkPairProve(
                nonce: LinkBytes16(payload.nonce), deviceName: pairName, ipadSPKIHash: LinkBytes32(ownSPKIHash), mac: LinkBytes32(mac))
        else { return fail(.pairingFailed("cannot build proof")) }
        return [.send(.pairProve(prove))]
    }

    mutating func receive(_ message: LinkMessage) -> [Action] {
        guard phase != .finished, phase != .idle else { return [] }
        if case .close(let code, _) = message { return fail(.fromPeerClose(code), notify: false) }
        if case .pairDenied(let reason) = message, phase != .awaitingWelcome {
            return fail(.pairingDenied(reason), notify: false)  // the helper may refuse at any pairing step
        }
        switch (phase, message) {
        case (.awaitingWelcome, .welcome(let w)):
            return handleWelcome(w)
        case (.awaitingWelcome, .approvalRequired), (.awaitingPairResult, .approvalRequired):
            macApproving = true
            return [.event(.awaitingMacApproval)]
        case (.awaitingWelcome, .pairChallenge), (.awaitingPairResult, .pairChallenge):
            return []  // a helper without a TLS exporter sends one unconditionally; only QR pairing needs it
        case (.awaitingChallenge, .pairChallenge(let c)):
            guard case .pairWithQR(let payload) = mode else { return fail(.protocolViolation("unexpected challenge")) }
            let actions = sendProve(payload: payload, challenge: c.data)
            if phase != .finished { phase = .awaitingPairResult }
            return actions
        case (.awaitingPairResult, .pairOK(let ok)):
            paired = true
            phase = .awaitingWelcome
            return [.event(.paired(macName: ok.macName, helperID: ok.helperID.data))]
        case (.awaitingPairResult, .pairDenied(let reason)):
            return fail(.pairingDenied(reason), notify: false)
        case (.sasAwaitPeerCommit, .sasCommit(let c)):
            guard var exchange = sas, (try? exchange.receivePeerCommit(c.data)) != nil,
                  let reveal = try? LinkBytes32(exchange.reveal)
            else { return fail(.protocolViolation("sas commit")) }
            sas = exchange
            phase = .sasAwaitPeerReveal
            return [.send(.sasReveal(reveal))]
        case (.sasAwaitPeerReveal, .sasReveal(let r)):
            guard var exchange = sas, (try? exchange.receivePeerReveal(r.data)) != nil,
                  let code = try? exchange.code(transcript: SASConfirmation.transcript(macSPKIHash: peerSPKIHash, ipadSPKIHash: ownSPKIHash))
            else { return fail(.pairingFailed("sas reveal does not match its commit")) }
            sas = exchange
            phase = .sasAwaitUser
            return [.event(.sasCode(code))]
        default:
            return fail(.protocolViolation("unexpected \(message.type)"))
        }
    }

    /// The user's answer to `Event.sasCode`: did the digits match the ones on the Mac? A "yes" only tells the Mac the iPad
    /// side is done (`sas.confirm`); it carries nothing computed from the digits, so a peer that sees it learns nothing it
    /// could test guesses against.
    mutating func sasDecision(confirmed: Bool) -> [Action] {
        guard phase == .sasAwaitUser else { return [] }
        guard confirmed else { return fail(.sasRejected) }
        phase = .awaitingPairResult
        return [.send(.sasConfirm)]
    }

    private mutating func handleWelcome(_ w: LinkWelcome) -> [Action] {
        guard let range = hello.protocolRange,
              range.contains(w.protocolVersion), LinkProtocolVersion.supported.contains(w.protocolVersion)
        else { return fail(.versionMismatch(.remoteTooNew(remoteMin: w.protocolVersion))) }
        phase = .finished  // the machine's job is done
        let info = LinkSessionInfo(
            protocolVersion: w.protocolVersion, capabilities: w.capabilities.intersection(hello.capabilities),
            sessionID: w.sessionID, resumeToken: w.resumeToken.data, macName: w.macName, displays: w.displays)
        return [.event(.ready(info))]
    }
}

// MARK: - Helper

/// What the helper's UI is asked to approve. Approval is a local act on the Mac (LocalAuthentication, injected by the app).
/// For SAS pairing `sasCode` is the six digits to DISPLAY next to the device name; the person compares them with the iPad
/// and approves or denies. The code is never sent to the iPad as an answer: it is not a secret to type, only a thing to compare.
public struct PairingApprovalRequest: Sendable, Equatable {
    public enum Reason: Sendable, Equatable {
        /// A new iPad wants to pair (`method` says how it proved itself).
        case newPairing(Method)
        /// A paired iPad connects and the Mac is set to "ask before each session".
        case session
    }
    public enum Method: Sendable, Equatable { case qr, sas }

    public var reason: Reason
    /// Sanitised: no control characters, at most 64 bytes. Still untrusted text: show it, never act on it.
    public var deviceName: String
    public var deviceSPKIHash: Data
    /// In SAS pairing, the six digits the Mac user should see matching on the iPad.
    public var sasCode: String?
}

/// What the helper app learns when a session is established.
public struct HelperSessionReady: Sendable, Equatable {
    public var deviceName: String
    public var deviceSPKIHash: Data
    public var clientHello: LinkHello
    public var protocolVersion: UInt16
    public var capabilities: LinkCapabilities
    public var sessionID: UInt64
    /// The iPad presented a valid resume token (single use, bound to its identity).
    public var resumed: Bool
    /// `lastStateVersion` the iPad sent with a valid resume token.
    public var lastStateVersion: UInt64?
    /// The device was paired during this connection.
    public var newlyPaired: Bool
}

struct HelperSessionMachine {
    struct Configuration: Sendable {
        var macName: String
        var helperSPKIHash: Data
        var capabilities: LinkCapabilities
        var displays: [LinkDisplayInfo]
        /// Evaluated when the device asks to resume, so a change in settings applies to handshakes already under way.
        var askBeforeEachSession: @Sendable () -> Bool
    }

    enum Action: Equatable {
        case send(LinkMessage)
        case ready(HelperSessionReady)
        case requestApproval(PairingApprovalRequest)
        /// Make this true atomically (see `HandshakeCommit`), then call `commitResult`.
        case commit(HandshakeCommit)
        case terminate(LinkSessionError, notifyPeer: Bool)
    }

    private enum Phase {
        case awaitingHello, awaitingFirst
        case sasAwaitReveal, sasAwaitConfirm
        case awaitingApproval, awaitingCommit, finished
    }

    private enum PendingApproval {
        case pairing(name: String, method: PairingApprovalRequest.Method)
        case session(resumed: Bool, lastStateVersion: UInt64?)
    }

    let configuration: Configuration
    let peerSPKIHash: Data
    let exporter: Data?
    private let devices: any PairedDeviceStore
    private let ledger: PairingSecretLedger
    private let resumeTokens: ResumeTokenStore
    private let admission: PairingAdmission
    private let source: String
    private let clock: LinkClock

    private var phase = Phase.awaitingHello
    private var clientHello: LinkHello?
    private var version: UInt16 = 0
    private var challenge: Data?
    private var sas: SASExchange?
    private var sasCode: String?
    private var pending: PendingApproval?
    private enum Committing { case pairing(name: String), session(resumed: Bool, lastStateVersion: UInt64?) }
    private var committing: Committing?
    private let startEpoch: UInt64
    /// The admission claim this handshake holds while it proves or waits for approval. The connection driver releases it
    /// whenever the handshake ends, however it ends.
    private(set) var claimID: UInt64?

    init(
        configuration: Configuration, peerSPKIHash: Data, exporter: Data?, devices: any PairedDeviceStore,
        ledger: PairingSecretLedger, resumeTokens: ResumeTokenStore, admission: PairingAdmission = PairingAdmission(),
        source: String = LinkRemoteAddress.unknown, clock: @escaping LinkClock = { Date() }
    ) {
        self.configuration = configuration
        self.peerSPKIHash = peerSPKIHash
        self.exporter = exporter
        self.devices = devices
        self.ledger = ledger
        self.resumeTokens = resumeTokens
        self.admission = admission
        self.startEpoch = admission.epoch
        self.source = source
        self.clock = clock
    }

    var isFinished: Bool { phase == .finished }

    /// Seconds the current phase may take, or `nil` when it waits for a person (approval has its own deadline).
    var phaseTimeout: TimeInterval? {
        switch phase {
        case .awaitingApproval, .awaitingCommit, .finished: nil
        case .sasAwaitConfirm: 150  // the person at the iPad compares digits
        default: 10
        }
    }

    private mutating func fail(_ error: LinkSessionError, notify: Bool = true) -> [Action] {
        phase = .finished
        releaseClaim()
        return [.terminate(error, notifyPeer: notify)]
    }

    mutating func releaseClaim() {
        admission.release(claimID)
        claimID = nil
    }

    private mutating func deny(_ reason: LinkPairDenyReason) -> [Action] {
        phase = .finished
        releaseClaim()
        return [.send(.pairDenied(reason)), .terminate(.pairingDenied(reason), notifyPeer: false)]
    }

    mutating func receive(_ message: LinkMessage) -> [Action] {
        if phase == .finished { return [] }
        if case .close(let code, _) = message { return fail(.fromPeerClose(code), notify: false) }
        switch (phase, message) {
        case (.awaitingHello, .hello(let h)): return handleHello(h)
        case (.awaitingFirst, .resume(let r)): return handleResume(r)
        case (.awaitingFirst, .pairProve(let p)): return handleQRProve(p)
        case (.awaitingFirst, .sasCommit(let c)): return handleSASCommit(c)
        case (.sasAwaitReveal, .sasReveal(let r)): return handleSASReveal(r)
        case (.sasAwaitConfirm, .sasConfirm): return handleSASConfirm()
        default: return fail(.protocolViolation("unexpected \(message.type)"))
        }
    }

    private mutating func handleHello(_ h: LinkHello) -> [Action] {
        guard let range = h.protocolRange else { return fail(.protocolViolation("hello version range")) }
        switch LinkVersionNegotiation.evaluate(local: LinkProtocolVersion.supported, remote: range) {
        case .agreed(let v): version = v
        case let other: return fail(.versionMismatch(other))
        }
        clientHello = h
        phase = .awaitingFirst
        guard exporter == nil else { return [] }
        // No TLS exporter on this transport: bind the pairing proof to a fresh challenge instead.
        guard let c = try? LinkRandom.bytes(32), let bytes = try? LinkBytes32(c) else { return fail(.transport("random")) }
        challenge = c
        return [.send(.pairChallenge(bytes))]
    }

    // MARK: Reconnect

    private mutating func handleResume(_ r: LinkResume) -> [Action] {
        guard let device = devices.device(spkiHash: peerSPKIHash) else { return fail(.notAuthorized) }
        var resumed = false
        // An all-zero token means "no token": nothing to consume.
        if r.resumeToken.data != Data(repeating: 0, count: 32) {
            resumed = resumeTokens.consume(r.resumeToken.data, identityHash: peerSPKIHash)
        }
        let version = resumed ? r.lastStateVersion : nil
        if configuration.askBeforeEachSession() {
            pending = .session(resumed: resumed, lastStateVersion: version)
            phase = .awaitingApproval
            return [
                .send(.approvalRequired),
                .requestApproval(PairingApprovalRequest(reason: .session, deviceName: device.name, deviceSPKIHash: peerSPKIHash, sasCode: nil)),
            ]
        }
        committing = .session(resumed: resumed, lastStateVersion: version)
        phase = .awaitingCommit
        return [.commit(.session)]
    }

    // MARK: QR pairing

    private mutating func handleQRProve(_ p: LinkPairProve) -> [Action] {
        // The admission is the offer itself: only a proof naming an outstanding QR nonce gets past the ledger. One attempt at a
        // time: claim before the ledger is touched, so a second device cannot burn the offer or pair beside this one.
        guard let claim = admission.claim(epoch: startEpoch) else { return deny(.busy) }
        claimID = claim
        let name = p.deviceName
        guard constantTimeEqual(p.ipadSPKIHash.data, peerSPKIHash),
              name.utf8.count <= PairingProof.maxDeviceNameBytes, !name.isEmpty
        else { return deny(.badProof) }
        let exporter = self.exporter, challenge = self.challenge
        let macHash = configuration.helperSPKIHash, ipadHash = peerSPKIHash, received = p.mac.data
        do {
            try ledger.attempt(nonce: p.nonce.data, source: source) { offer in
                let binding: PairingBinding
                if let exporter { binding = .exporter(exporter) }
                else if let challenge { binding = .helperChallenge(nonce: offer.nonce, challenge: challenge) }
                else { return false }
                return PairingProof.verify(
                    mac: received, secret: offer.secret, nonce: offer.nonce, binding: binding,
                    macSPKIHash: macHash, ipadSPKIHash: ipadHash, deviceName: name)
            }
        } catch let e as PairingError {
            switch e {
            case .tooManyAttempts: return deny(.tooManyAttempts)
            case .rateLimited: return deny(.busy)
            case .unknownOrUsedSecret, .expired: return deny(.expired)
            default: return deny(.badProof)
            }
        } catch { return deny(.badProof) }
        let safeName = SessionText.sanitizedDeviceName(name)
        pending = .pairing(name: safeName, method: .qr)
        phase = .awaitingApproval
        return [
            .send(.approvalRequired),
            .requestApproval(PairingApprovalRequest(
                reason: .newPairing(.qr), deviceName: safeName, deviceSPKIHash: peerSPKIHash, sasCode: nil)),
        ]
    }

    // MARK: SAS pairing

    private mutating func handleSASCommit(_ c: LinkBytes32) -> [Action] {
        do { try admission.beginSAS(source: source) } catch PairingAdmissionError.tooManySASAttempts {
            return deny(.tooManyAttempts)
        } catch { return deny(.unsupported) }  // no pairing window is open
        var exchange = SASExchange()
        guard (try? exchange.receivePeerCommit(c.data)) != nil, let commit = try? LinkBytes32(exchange.commit) else {
            return fail(.protocolViolation("sas commit"))
        }
        sas = exchange
        phase = .sasAwaitReveal
        return [.send(.sasCommit(commit))]
    }

    private mutating func handleSASReveal(_ r: LinkBytes32) -> [Action] {
        guard var exchange = sas, (try? exchange.receivePeerReveal(r.data)) != nil,
              let mine = try? LinkBytes32(exchange.reveal),
              let code = try? exchange.code(transcript: SASConfirmation.transcript(
                  macSPKIHash: configuration.helperSPKIHash, ipadSPKIHash: peerSPKIHash))
        else { return fail(.pairingFailed("sas reveal does not match its commit")) }
        sas = exchange
        sasCode = code
        phase = .sasAwaitConfirm
        return [.send(.sasReveal(mine))]
    }

    /// The iPad user says the digits match. Now the person at the Mac compares them (the approval handler shows them) and
    /// approves locally. Neither answer is derived from the digits.
    private mutating func handleSASConfirm() -> [Action] {
        guard let code = sasCode, let hello = clientHello else { return fail(.protocolViolation("sas state")) }
        let safeName = SessionText.sanitizedDeviceName(hello.deviceName)
        guard let claim = admission.claim(epoch: startEpoch) else { return deny(.busy) }
        claimID = claim
        pending = .pairing(name: safeName, method: .sas)
        phase = .awaitingApproval
        return [
            .send(.approvalRequired),
            .requestApproval(PairingApprovalRequest(
                reason: .newPairing(.sas), deviceName: safeName, deviceSPKIHash: peerSPKIHash, sasCode: code)),
        ]
    }

    // MARK: Approval, commit and welcome

    /// The local approval (LocalAuthentication on the Mac) finished.
    mutating func approvalResult(_ approved: Bool) -> [Action] {
        guard phase == .awaitingApproval, let pending else { return [] }
        self.pending = nil
        switch pending {
        case .pairing(let name, let method):
            guard approved else {
                if case .sas = method { admission.close() }  // one denial closes the SAS window
                return deny(.userDenied)
            }
            committing = .pairing(name: name)
            phase = .awaitingCommit
            return [.commit(.pairing(PairedDevice(spkiHash: peerSPKIHash, name: name, pairedAt: clock()), method: method, epoch: startEpoch))]
        case .session(let resumed, let lastStateVersion):
            guard approved else { return fail(.approvalDenied) }
            committing = .session(resumed: resumed, lastStateVersion: lastStateVersion)
            phase = .awaitingCommit
            return [.commit(.session)]
        }
    }

    /// The server's answer to `.commit`. Admission is decided there, atomically with the paired-device store, so nothing is
    /// admitted after a revoke, a stop or a disconnect that happened while this handshake was waiting.
    mutating func commitResult(_ result: CommitResult) -> [Action] {
        guard phase == .awaitingCommit, let committing else { return [] }
        self.committing = nil
        guard case .admitted(let token, let storedName) = result else {
            switch result {
            case .windowClosed: return deny(.expired)
            case .storeFull: return deny(.busy)
            default: return fail(.notAuthorized)
            }
        }
        switch committing {
        case .pairing(let name):
            guard let helperID = try? LinkBytes32(configuration.helperSPKIHash) else { return fail(.transport("helper id")) }
            return welcome(
                deviceName: name, token: token, resumed: false, lastStateVersion: nil, newlyPaired: true,
                extra: [.send(.pairOK(LinkPairOK(macName: configuration.macName, helperID: helperID)))])
        case .session(let resumed, let lastStateVersion):
            return welcome(
                deviceName: storedName, token: token, resumed: resumed, lastStateVersion: lastStateVersion, newlyPaired: false, extra: [])
        }
    }

    private mutating func welcome(
        deviceName: String, token: Data, resumed: Bool, lastStateVersion: UInt64?, newlyPaired: Bool, extra: [Action]
    ) -> [Action] {
        guard let hello = clientHello, let tokenBytes = try? LinkBytes32(token), let idBytes = try? LinkRandom.bytes(8)
        else { return fail(.transport("cannot issue session")) }
        let sessionID = idBytes.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) } | 1  // never zero
        let caps = configuration.capabilities.intersection(hello.capabilities)
        phase = .finished
        let welcome = LinkWelcome(
            protocolVersion: version, sessionID: sessionID, resumeToken: tokenBytes, macName: configuration.macName,
            displays: configuration.displays, capabilities: caps)
        return extra + [
            .send(.welcome(welcome)),
            .ready(HelperSessionReady(
                deviceName: deviceName, deviceSPKIHash: peerSPKIHash, clientHello: hello, protocolVersion: version,
                capabilities: caps, sessionID: sessionID, resumed: resumed, lastStateVersion: lastStateVersion,
                newlyPaired: newlyPaired)),
        ]
    }
}

/// What the helper must make true, atomically, before it may send `welcome`.
enum HandshakeCommit: Equatable {
    /// An approved new pairing: store the device. `epoch` is `PairingAdmission.epoch` when the handshake began; a pairing
    /// that succeeded in the meantime makes this one stale.
    case pairing(PairedDevice, method: PairingApprovalRequest.Method, epoch: UInt64)
    /// A paired device is let in: it must still be paired.
    case session
}

enum CommitResult: Equatable {
    case admitted(resumeToken: Data, deviceName: String)
    /// Revoked, stopped or disconnected, or no longer paired.
    case notAuthorized
    /// The pairing window closed or another pairing succeeded first.
    case windowClosed
    case storeFull
}

extension HandshakeCommit {
    /// The state change behind a commit. `LinkServer` calls this from inside its actor right after checking that the handshake
    /// is still alive; tests call it directly. It touches the store, the admission and the token store in one synchronous step.
    func apply(
        peerSPKIHash: Data, devices: any PairedDeviceStore, admission: PairingAdmission, ledger: PairingSecretLedger,
        resumeTokens: ResumeTokenStore
    ) -> CommitResult {
        let name: String
        switch self {
        case .session:
            guard let device = devices.device(spkiHash: peerSPKIHash) else { return .notAuthorized }
            name = device.name
        case .pairing(let device, let method, let epoch):
            guard admission.epoch == epoch else { return .windowClosed }
            if case .sas = method, !admission.isOpen { return .windowClosed }
            do { try devices.add(device) } catch { return .storeFull }
            admission.recordPairingSuccess()
            ledger.revokeAll()
            name = device.name
        }
        guard let token = try? resumeTokens.issue(for: peerSPKIHash) else { return .notAuthorized }
        return .admitted(resumeToken: token, deviceName: name)
    }
}
