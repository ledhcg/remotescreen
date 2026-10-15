import Foundation
import LinkProtocol
import Testing
@testable import LinkTransport

/// One helper/iPad identity pair for the whole test process (and, only when software identities are unavailable, one
/// temporary keychain). Creating identities in a keychain costs ~0.5 s, so they are shared; every test still gets its own
/// servers, paired-device stores and sessions. The keychain file, if any, is deleted at exit.
final class SharedTestIdentities: @unchecked Sendable {
    let keychain: TempKeychain?
    let helperIdentity: LinkIdentity
    let ipadIdentity: LinkIdentity
    let helperSec: LinkSecIdentity
    let ipadSec: LinkSecIdentity

    private init(keychain: TempKeychain?, h: LinkIdentity, i: LinkIdentity, hs: LinkSecIdentity, isec: LinkSecIdentity) {
        self.keychain = keychain; helperIdentity = h; ipadIdentity = i; helperSec = hs; ipadSec = isec
    }

    nonisolated(unsafe) private static var cleanup: (() -> Void)?

    /// A `SecIdentity` for `identity`: software (fast) if possible, otherwise via the temporary keychain.
    func secIdentity(for identity: LinkIdentity) throws -> LinkSecIdentity {
        if let soft = SoftwareIdentity.make(for: identity) { return LinkSecIdentity(soft) }
        guard let keychain else { throw LinkIdentityError.unsupported("no identity source") }
        return LinkSecIdentity(try keychain.secIdentity(for: identity))
    }

    /// `nil` when no identity can be created here.
    static let instance: SharedTestIdentities? = {
        do {
            let h = try LinkIdentity.generate(role: .helper), i = try LinkIdentity.generate(role: .ipad)
            if let hs = SoftwareIdentity.make(for: h), let isec = SoftwareIdentity.make(for: i) {
                return SharedTestIdentities(keychain: nil, h: h, i: i, hs: LinkSecIdentity(hs), isec: LinkSecIdentity(isec))
            }
            guard let kc = TempKeychain() else { return nil }
            do {
                let shared = SharedTestIdentities(
                    keychain: kc, h: h, i: i, hs: LinkSecIdentity(try kc.secIdentity(for: h)), isec: LinkSecIdentity(try kc.secIdentity(for: i)))
                cleanup = { kc.cleanUp() }
                atexit { SharedTestIdentities.cleanup?() }
                return shared
            } catch {
                kc.cleanUp()
                return nil
            }
        } catch { return nil }
    }()
}

/// Everything an end-to-end loopback test needs: the shared identities, a server bound to 127.0.0.1, per-test stores, and a
/// way to build client configurations. Nothing leaves the machine.
final class LoopbackRig: @unchecked Sendable {
    let shared: SharedTestIdentities
    let helperIdentity: LinkIdentity
    let ipadIdentity: LinkIdentity
    let helperSec: LinkSecIdentity
    let ipadSec: LinkSecIdentity
    let devices = InMemoryPairedDeviceStore()
    let approvals = ApprovalLog()
    let macs = InMemoryPairedMacStore()
    private let lock = NSLock()
    private var servers: [LinkServer] = []
    private var sasOpen = false

    var sasPairingOpen: Bool {
        get { lock.withLock { sasOpen } }
        set { lock.withLock { sasOpen = newValue } }
    }

    /// Skips the test (does not fail it) when a temporary keychain cannot be created on this machine.
    static func make() throws -> LoopbackRig {
        guard let shared = SharedTestIdentities.instance else {
            try Test.cancel("cannot create a temporary keychain / TLS identity on this machine")
            fatalError("unreachable")
        }
        return LoopbackRig(
            shared: shared, helperIdentity: shared.helperIdentity, ipadIdentity: shared.ipadIdentity,
            helperSec: shared.helperSec, ipadSec: shared.ipadSec)
    }

    /// An additional iPad identity (a second device) in the shared keychain.
    func makeExtraIPad() throws -> (LinkIdentity, LinkSecIdentity) {
        let id = try LinkIdentity.generate(role: .ipad)
        return (id, try shared.secIdentity(for: id))
    }

    private init(shared: SharedTestIdentities, helperIdentity: LinkIdentity, ipadIdentity: LinkIdentity, helperSec: LinkSecIdentity, ipadSec: LinkSecIdentity) {
        self.shared = shared; self.helperIdentity = helperIdentity; self.ipadIdentity = ipadIdentity
        self.helperSec = helperSec; self.ipadSec = ipadSec
    }

    func tearDown() async {
        let all = lock.withLock { servers }
        for s in all { await s.stop() }
        try? await Task.sleep(for: .milliseconds(20))
    }

    var ipadSPKI: Data { ipadIdentity.spkiHash }
    var helperSPKI: Data { helperIdentity.spkiHash }

    func makeServer(
        enableQUIC: Bool = true, enableTCP: Bool = true, askBeforeEachSession: Bool = false,
        snapshot: LinkSnapshot? = nil, maxSessions: Int = 4, loopbackOnly: Bool = true
    ) async throws -> (LinkServer, LinkServerEndpoint) {
        let log = approvals
        let config = LinkServerConfiguration(
            identity: helperSec, macName: "Test Mac", capabilities: [.hevc, .menus, .gestures], pairedDevices: devices,
            approvalHandler: { request in await log.decide(request) },
            approvalTimeout: .seconds(5),
            snapshotProvider: snapshot.map { snap in { @Sendable _ in snap } },
            askBeforeEachSession: { askBeforeEachSession },
            sasPairingEnabled: { [weak self] in self?.sasPairingOpen ?? false },
            enableQUIC: enableQUIC, enableTCP: enableTCP, loopbackOnly: loopbackOnly, maxSessions: maxSessions)
        let server = try LinkServer(configuration: config)
        let endpoint = try await server.start()
        lock.withLock { servers.append(server) }
        return (server, endpoint)
    }

    func clientConfiguration(
        mode: LinkClientMode, transport: LinkTransportPreference, pin: Data? = nil, sas: (@Sendable (String) async -> Bool)? = nil,
        computerID: String? = "mac-1", quicTimeout: Duration = .seconds(3), identity: LinkSecIdentity? = nil
    ) -> LinkClientConfiguration {
        LinkClientConfiguration(
            identity: identity ?? ipadSec, deviceName: "Test iPad", capabilities: [.hevc, .gestures, .tablet],
            sceneLimits: LinkSceneLimits(maxWindows: 8, maxStreams: 16, maxPixelWidth: 2732, maxPixelHeight: 2048, maxFramesPerSecond: 60),
            mode: mode, pinnedMacSPKIHash: pin, transport: transport, quicTimeout: quicTimeout, connectTimeout: .seconds(8),
            sasConfirmation: sas, pairedMacStore: macs, computerID: computerID)
    }

    func endpoint(_ e: LinkServerEndpoint, transport: LinkTransportKind) -> LinkEndpoint {
        LinkEndpoint(host: "127.0.0.1", port: transport == .quic ? (e.quicPort ?? 0) : (e.tcpPort ?? 0))
    }
}

/// Records approval requests and answers them.
actor ApprovalLog {
    private(set) var requests: [PairingApprovalRequest] = []
    private var answer = true
    func setAnswer(_ a: Bool) { answer = a }
    func decide(_ r: PairingApprovalRequest) -> Bool { requests.append(r); return answer }
}

extension LinkTransportKind {
    var preference: LinkTransportPreference { self == .quic ? .quic : .tcp }
}

/// Reads the next element within `timeout` or returns nil.
func nextElement<T: Sendable>(_ inbox: LinkInbox<T>, timeout: Duration = .seconds(5)) async -> T? {
    await withTimeout(timeout) { var it = inbox.makeAsyncIterator(); return await it.next() } ?? nil
}

/// Collects `LinkEvent`s from a stream and lets a test wait for one.
actor EventLog {
    private(set) var events: [LinkEvent] = []
    private var waiters: [(id: Int, predicate: @Sendable (LinkEvent) -> Bool, cont: CheckedContinuation<LinkEvent?, Never>)] = []
    private var nextID = 0

    init(_ stream: AsyncStream<LinkEvent>) {
        Task { [weak self] in
            for await e in stream { await self?.append(e) }
        }
    }

    private func append(_ e: LinkEvent) {
        events.append(e)
        for w in waiters where w.predicate(e) { w.cont.resume(returning: e) }
        waiters.removeAll { $0.predicate(e) }
    }

    func wait(timeout: Duration = .seconds(5), where predicate: @escaping @Sendable (LinkEvent) -> Bool) async -> LinkEvent? {
        if let e = events.first(where: predicate) { return e }
        let id = nextID
        nextID += 1
        return await withCheckedContinuation { (cont: CheckedContinuation<LinkEvent?, Never>) in
            waiters.append((id, predicate, cont))
            Task {
                try? await Task.sleep(for: timeout)
                self.expire(id)
            }
        }
    }

    private func expire(_ id: Int) {
        guard let i = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: i).cont.resume(returning: nil)
    }
}

extension LinkEvent {
    var closedError: LinkSessionError?? {
        if case .closed(let e) = self { return .some(e) }
        return nil
    }
}

/// Whether `operation` finished within `timeout`.
func within(_ timeout: Duration, _ operation: @escaping @Sendable () async -> Void) async -> Bool {
    await withTimeout(timeout, operation) != nil
}
