import Foundation
import LinkProtocol
import Testing
@testable import LinkTransport

@Suite(.timeLimit(.minutes(2))) struct AdmissionReservationTests {
    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isOn: Bool { lock.withLock { value } }
        func set(_ v: Bool) { lock.withLock { value = v } }
    }

    private func isApprovalRequest(_ a: HelperSessionMachine.Action) -> Bool {
        if case .requestApproval = a { true } else { false }
    }

    /// A helper machine for a new device, sharing `ledger`, `admission` and `devices`, with its QR proof message ready.
    private func attempt(
        ledger: PairingSecretLedger, admission: PairingAdmission, devices: InMemoryPairedDeviceStore, clock: TestClock
    ) throws -> (rig: MachineRig, hello: LinkMessage, prove: LinkMessage) {
        var rig = try MachineRig.make(
            mode: .reconnect(nil), windowOpen: false, devices: devices, ledger: ledger, clock: clock, admission: admission)
        let offer = try ledger.issue()
        rig.client = ClientSessionMachine(
            hello: rig.client.hello,
            mode: .pairWithQR(PairingQRPayload(
                hostHints: ["h"], port: 1, macSPKIHash: rig.helperSPKI, secret: offer.secret, nonce: offer.nonce, expiry: offer.expiry)),
            ownSPKIHash: rig.clientSPKI, peerSPKIHash: rig.helperSPKI, exporter: Data(repeating: 7, count: 32))
        let sent = rig.client.start().compactMap { action -> LinkMessage? in
            if case .send(let m) = action { return m } else { return nil }
        }
        return (rig, sent[0], sent[1])
    }

    @Test func aSecondAttemptIsRefusedWhileOneIsInFlightAndGetsTheClaimAfterADenial() throws {
        let clock = TestClock()
        let ledger = PairingSecretLedger(clock: clock.clock)
        let admission = PairingAdmission(clock: clock.clock)
        let devices = InMemoryPairedDeviceStore()
        var a = try attempt(ledger: ledger, admission: admission, devices: devices, clock: clock)
        var b = try attempt(ledger: ledger, admission: admission, devices: devices, clock: clock)
        var c = try attempt(ledger: ledger, admission: admission, devices: devices, clock: clock)

        _ = a.rig.helper.receive(a.hello)
        #expect(a.rig.helper.receive(a.prove).contains(where: isApprovalRequest), "A waits for the Mac user")

        _ = b.rig.helper.receive(b.hello)
        let bActions = b.rig.helper.receive(b.prove)
        #expect(bActions.contains(.send(.pairDenied(.busy))), "B is refused while A is in flight")
        #expect(!bActions.contains(where: isApprovalRequest))

        // A is denied on the Mac: the claim comes back, and C may go.
        _ = a.rig.helper.approvalResult(false)
        _ = c.rig.helper.receive(c.hello)
        #expect(c.rig.helper.receive(c.prove).contains(where: isApprovalRequest))
        #expect(devices.all().isEmpty)
    }

    @Test func aStaleHandshakeCannotPairAfterAnotherSucceeded() throws {
        let clock = TestClock()
        let ledger = PairingSecretLedger(clock: clock.clock)
        let admission = PairingAdmission(clock: clock.clock)
        let devices = InMemoryPairedDeviceStore()
        var a = try attempt(ledger: ledger, admission: admission, devices: devices, clock: clock)
        var b = try attempt(ledger: ledger, admission: admission, devices: devices, clock: clock)
        _ = a.rig.helper.receive(a.hello)
        _ = a.rig.helper.receive(a.prove)
        _ = b.rig.helper.receive(b.hello)  // B's handshake began before A succeeded

        guard case .commit(let commitA)? = a.rig.helper.approvalResult(true).first else { Issue.record("expected commit"); return }
        let resultA = commitA.apply(
            peerSPKIHash: a.rig.helper.peerSPKIHash, devices: devices, admission: admission, ledger: ledger,
            resumeTokens: a.rig.resumeTokens)
        guard case .admitted = resultA else { Issue.record("A should be admitted"); return }

        // B's proof arrives late: its offer was burned by A's success and its handshake is stale.
        let bActions = b.rig.helper.receive(b.prove)
        #expect(bActions.contains { if case .send(.pairDenied) = $0 { true } else { false } })
        #expect(devices.all().count == 1)
    }

    @Test func askBeforeEachSessionIsReadWhenTheDeviceResumesNotWhenItConnected() throws {
        let flag = Flag()
        let devices = InMemoryPairedDeviceStore()
        var rig = try MachineRig.make(mode: .reconnect(nil), paired: true, devices: devices)
        rig.helper = HelperSessionMachine(
            configuration: .init(
                macName: "Test Mac", helperSPKIHash: rig.helperSPKI, capabilities: [], displays: [],
                askBeforeEachSession: { flag.isOn }),
            peerSPKIHash: rig.clientSPKI, exporter: Data(repeating: 7, count: 32), devices: devices, ledger: rig.ledger,
            resumeTokens: rig.resumeTokens, admission: rig.admission, clock: rig.clock.clock)
        flag.set(true)  // the Mac user turned the setting on after the connection was accepted
        let out = rig.run(approve: false)
        #expect(out.approvals.map(\.reason) == [.session])
        #expect(out.helperError == .approvalDenied)
        #expect(out.helperReady == nil)
    }
}
