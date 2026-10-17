import Foundation
import LinkProtocol
import Testing
@testable import LinkTransport

/// Interleavings of revoke / stop / disconnect / closing the pairing window with a handshake that is waiting for the person
/// at the Mac. The "Mac user" is a controllable continuation (`ApprovalLog.hold`), so there are no sleeps: every step waits on
/// an event.
@Suite(.timeLimit(.minutes(1))) struct AuthorizationRaceTests {
    private func connect(
        _ rig: LoopbackRig, _ target: LinkEndpoint, mode: LinkClientMode, identity: LinkSecIdentity? = nil,
        pin: Data? = nil, sas: (@Sendable (String) async -> Bool)? = nil
    ) -> Task<Result<LinkConnection, LinkSessionError>, Never> {
        let config = rig.clientConfiguration(mode: mode, transport: .tcp, pin: pin, sas: sas, identity: identity)
        return Task {
            do { return .success(try await LinkConnection.connect(to: target, configuration: config)) }
            catch { return .failure((error as? LinkSessionError) ?? .transport("other")) }
        }
    }

    private func expectFailure(_ r: Result<LinkConnection, LinkSessionError>, _ note: Comment) async {
        if case .success(let c) = r {
            Issue.record("device was admitted: \(note)")
            await c.close()
        }
    }

    private func qr(_ server: LinkServer) async throws -> LinkClientMode {
        .pairWithQR(try await server.makePairingQRPayload(hostHints: ["127.0.0.1"]))
    }

    // MARK: Revoke

    @Test func revokeWhileANewPairingWaitsForApprovalDoesNotAdmit() async throws {
        let rig = try LoopbackRig.make()
        let (server, ep) = try await rig.makeServer(enableQUIC: false)
        let target = rig.endpoint(ep, transport: .tcp)
        await rig.approvals.hold(true)
        let attempt = connect(rig, target, mode: try await qr(server))
        await rig.approvals.waitForRequests(1)

        _ = try await server.revoke(deviceSPKIHash: rig.ipadSPKI)
        // The server cancels the prompt first (that is what the test is about); only then does the Mac user tap Approve.
        // Approve before the cancel is processed is also legal and is covered by the tests that do not count cancelled prompts: both
        // orders must not admit, but only this one makes "the prompt was cancelled" a fact that can be waited for.
        await rig.approvals.waitForCancelledPrompts(1)
        await rig.approvals.release(true)  // the Mac user taps Approve a moment too late

        await expectFailure(await attempt.value, "approval completed after revoke")
        #expect(rig.devices.all().isEmpty, "a revoked handshake must not store the device")
        #expect(await server.activeSessions.isEmpty)
        #expect(await rig.approvals.cancelledPrompts == 1, "the pending prompt was cancelled")
        await rig.tearDown()
    }

    @Test func revokeWhileASessionApprovalIsPendingDoesNotAdmit() async throws {
        let rig = try LoopbackRig.make()
        let (server, ep) = try await rig.makeServer(enableQUIC: false, askBeforeEachSession: true)
        let target = rig.endpoint(ep, transport: .tcp)
        let first = try await LinkConnection.connect(
            to: target, configuration: rig.clientConfiguration(mode: try await qr(server), transport: .tcp))
        await first.close()

        await rig.approvals.hold(true)
        let attempt = connect(rig, target, mode: .reconnect(nil), pin: rig.helperSPKI)
        await rig.approvals.waitForRequests(2)
        _ = try await server.revoke(deviceSPKIHash: rig.ipadSPKI)
        await rig.approvals.release(true)

        await expectFailure(await attempt.value, "session approval completed after revoke")
        #expect(rig.devices.all().isEmpty)
        #expect(await server.activeSessions.isEmpty)
        await rig.tearDown()
    }

    @Test func revokeClosesLiveConnectionsAndInvalidatesResumeTokens() async throws {
        let rig = try LoopbackRig.make()
        let (server, ep) = try await rig.makeServer(enableQUIC: false)
        let target = rig.endpoint(ep, transport: .tcp)
        let conn = try await LinkConnection.connect(
            to: target, configuration: rig.clientConfiguration(mode: try await qr(server), transport: .tcp))
        let token = conn.session.resumeToken
        #expect(await server.activeSessions.count == 1)

        _ = try await server.revoke(deviceSPKIHash: rig.ipadSPKI)
        await conn.waitUntilClosed()
        #expect(await server.activeSessions.isEmpty)
        // The token the device held no longer resumes anything, even if the same key is paired again later.
        #expect(!server.resumeTokens.consume(token, identityHash: rig.ipadSPKI))
        await rig.tearDown()
    }

    @Test func revokeInvalidatesOutstandingTokensDirectly() async throws {
        let rig = try LoopbackRig.make()
        let (server, _) = try await rig.makeServer(enableQUIC: false)
        let other = try LinkRandom.bytes(32)
        let mine = try server.resumeTokens.issue(for: rig.ipadSPKI)
        let theirs = try server.resumeTokens.issue(for: other)
        _ = try await server.revoke(deviceSPKIHash: rig.ipadSPKI)
        #expect(!server.resumeTokens.consume(mine, identityHash: rig.ipadSPKI))
        #expect(server.resumeTokens.consume(theirs, identityHash: other), "other devices keep their tokens")
        await rig.tearDown()
    }

    // MARK: Stop and disconnect

    @Test func stopWhileApprovalIsPendingDoesNotAdmit() async throws {
        let rig = try LoopbackRig.make()
        let (server, ep) = try await rig.makeServer(enableQUIC: false)
        let target = rig.endpoint(ep, transport: .tcp)
        await rig.approvals.hold(true)
        let attempt = connect(rig, target, mode: try await qr(server))
        await rig.approvals.waitForRequests(1)

        await server.stop()
        // The server cancels the prompt first (that is what the test is about); only then does the Mac user tap Approve.
        // Approve before the cancel is processed is also legal and is covered by the tests that do not count cancelled prompts: both
        // orders must not admit, but only this one makes "the prompt was cancelled" a fact that can be waited for.
        await rig.approvals.waitForCancelledPrompts(1)
        await rig.approvals.release(true)

        await expectFailure(await attempt.value, "approval completed after stop")
        #expect(rig.devices.all().isEmpty)
        #expect(await rig.approvals.cancelledPrompts == 1)
        #expect(!server.pairingAdmission.isOpen)
        await rig.tearDown()
    }

    @Test func stopBurnsOutstandingOffersAndTheClaim() async throws {
        let rig = try LoopbackRig.make()
        let (server, _) = try await rig.makeServer(enableQUIC: false)
        let offer = try server.pairingLedger.issue()
        server.pairingAdmission.open()
        let claim = server.pairingAdmission.claim(epoch: server.pairingAdmission.epoch)
        #expect(claim != nil)

        await server.stop()
        #expect(throws: PairingError.unknownOrUsedSecret) {
            try server.pairingLedger.attempt(nonce: offer.nonce, source: "a") { _ in true }
        }
        #expect(!server.pairingAdmission.isOpen)
        #expect(server.pairingAdmission.claim(epoch: server.pairingAdmission.epoch) != nil, "the claim was dropped")
        await rig.tearDown()
    }

    @Test func disconnectAllWhileApprovalIsPendingDoesNotAdmitAndReleasesTheClaim() async throws {
        let rig = try LoopbackRig.make()
        let (server, ep) = try await rig.makeServer(enableQUIC: false)
        let target = rig.endpoint(ep, transport: .tcp)
        await rig.approvals.hold(true)
        let attempt = connect(rig, target, mode: try await qr(server))
        await rig.approvals.waitForRequests(1)
        #expect(server.pairingAdmission.claim(epoch: server.pairingAdmission.epoch) == nil, "the attempt holds the claim")

        await server.disconnectAll()
        // The server cancels the prompt first (that is what the test is about); only then does the Mac user tap Approve.
        // Approve before the cancel is processed is also legal and is covered by the tests that do not count cancelled prompts: both
        // orders must not admit, but only this one makes "the prompt was cancelled" a fact that can be waited for.
        await rig.approvals.waitForCancelledPrompts(1)
        await rig.approvals.release(true)

        await expectFailure(await attempt.value, "approval completed after disconnectAll")
        #expect(rig.devices.all().isEmpty)
        #expect(await rig.approvals.cancelledPrompts == 1)
        // The connection ended, so its claim was given back.
        #expect(server.pairingAdmission.claim(epoch: server.pairingAdmission.epoch) != nil)
        await rig.tearDown()
    }

    // MARK: Closing the pairing window

    @Test func closingThePairingWindowCancelsAPendingSASApproval() async throws {
        let rig = try LoopbackRig.make()
        let (server, ep) = try await rig.makeServer(enableQUIC: false)
        let target = rig.endpoint(ep, transport: .tcp)
        await server.openPairingWindow()
        let outstanding = try await server.makePairingQRPayload(hostHints: ["127.0.0.1"])
        await rig.approvals.hold(true)
        let attempt = connect(rig, target, mode: .pairWithSAS, sas: { _ in true })
        await rig.approvals.waitForRequests(1)

        await server.closePairingWindow()
        // The server cancels the prompt first (that is what the test is about); only then does the Mac user tap Approve.
        // Approve before the cancel is processed is also legal and is covered by the tests that do not count cancelled prompts: both
        // orders must not admit, but only this one makes "the prompt was cancelled" a fact that can be waited for.
        await rig.approvals.waitForCancelledPrompts(1)
        await rig.approvals.release(true)

        await expectFailure(await attempt.value, "approval completed after the window closed")
        #expect(rig.devices.all().isEmpty)
        #expect(await rig.approvals.cancelledPrompts == 1)
        #expect(!(await server.isPairingWindowOpen()))
        // The QR code that was on screen is dead too.
        let (_, other) = try rig.makeExtraIPad()
        let late = connect(rig, target, mode: .pairWithQR(outstanding), identity: other)
        await expectFailure(await late.value, "QR offer survived closePairingWindow")
        #expect(rig.devices.all().isEmpty)
        await rig.tearDown()
    }

    // MARK: One pairing per admission

    @Test func twoConcurrentSASAttemptsOnOneWindowPairOnlyOne() async throws {
        let rig = try LoopbackRig.make()
        let (server, ep) = try await rig.makeServer(enableQUIC: false)
        let target = rig.endpoint(ep, transport: .tcp)
        await server.openPairingWindow()
        await rig.approvals.hold(true)

        let first = connect(rig, target, mode: .pairWithSAS, sas: { _ in true })
        await rig.approvals.waitForRequests(1)  // the first device is now waiting for the Mac user

        // A second device tries while the first is undecided: refused, and the Mac user is never asked about it.
        let (secondID, secondSec) = try rig.makeExtraIPad()
        let second = connect(rig, target, mode: .pairWithSAS, identity: secondSec, sas: { _ in true })
        switch await second.value {
        case .success(let c): Issue.record("second device paired on the same window"); await c.close()
        case .failure(let e): #expect(e == .pairingDenied(.busy))
        }
        #expect(await rig.approvals.requests.count == 1)

        await rig.approvals.release(true)
        guard case .success(let conn) = await first.value else { Issue.record("first device should pair"); return }
        await conn.close()
        #expect(rig.devices.all().map(\.spkiHash) == [rig.ipadSPKI])
        #expect(rig.devices.device(spkiHash: secondID.spkiHash) == nil)
        await rig.tearDown()
    }

    @Test func twoConcurrentQRAttemptsPairOnlyOne() async throws {
        let rig = try LoopbackRig.make()
        let (server, ep) = try await rig.makeServer(enableQUIC: false)
        let target = rig.endpoint(ep, transport: .tcp)
        let modeA = try await qr(server)
        let modeB = try await qr(server)  // a second code on screen
        await rig.approvals.hold(true)

        let first = connect(rig, target, mode: modeA)
        await rig.approvals.waitForRequests(1)
        let (secondID, secondSec) = try rig.makeExtraIPad()
        let second = connect(rig, target, mode: modeB, identity: secondSec)
        switch await second.value {
        case .success(let c): Issue.record("second device paired while the first was pending"); await c.close()
        case .failure(let e): #expect(e == .pairingDenied(.busy))
        }
        await rig.approvals.release(true)
        guard case .success(let conn) = await first.value else { Issue.record("first device should pair"); return }
        await conn.close()
        #expect(rig.devices.all().count == 1)
        #expect(rig.devices.device(spkiHash: secondID.spkiHash) == nil)
        await rig.tearDown()
    }
}
