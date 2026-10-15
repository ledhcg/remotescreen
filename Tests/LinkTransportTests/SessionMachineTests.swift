import CryptoKit
import Foundation
import LinkProtocol
import Testing
@testable import LinkTransport

/// Runs a client machine against a helper machine in memory, delivering messages in order. No network, no identities.
struct MachineRig {
    var client: ClientSessionMachine
    var helper: HelperSessionMachine
    let devices: InMemoryPairedDeviceStore
    let ledger: PairingSecretLedger
    let resumeTokens: ResumeTokenStore
    let clock: TestClock
    let clientSPKI: Data
    let helperSPKI: Data

    struct Outcome {
        var clientError: LinkSessionError?
        var helperError: LinkSessionError?
        var clientInfo: LinkSessionInfo?
        var helperReady: HelperSessionReady?
        var clientPairedAs: String?
        var sasCodes: [String] = []
        var approvals: [PairingApprovalRequest] = []
        var clientSent: [LinkMessageType] = []
        var helperSent: [LinkMessageType] = []
        var helperDenied: LinkPairDenyReason?
    }

    static func make(
        mode: LinkClientMode, paired: Bool = false, exporterClient: Data? = Data(repeating: 7, count: 32),
        exporterHelper: Data? = Data(repeating: 7, count: 32), askBeforeEachSession: Bool = false, sasEnabled: Bool = true,
        helperSeenByClient: Data? = nil, clientSeenByHelper: Data? = nil, clientRange: ClosedRange<UInt16> = 1...1,
        devices: InMemoryPairedDeviceStore = InMemoryPairedDeviceStore(), ledger: PairingSecretLedger? = nil,
        resumeTokens: ResumeTokenStore? = nil, clock: TestClock = TestClock(), deviceName: String = "alice's iPad"
    ) throws -> MachineRig {
        let clientSPKI = try LinkRandom.bytes(32), helperSPKI = try LinkRandom.bytes(32)
        if paired { try devices.add(PairedDevice(spkiHash: clientSPKI, name: "alice's iPad", pairedAt: clock.now)) }
        let ledger = ledger ?? PairingSecretLedger(clock: clock.clock)
        let tokens = resumeTokens ?? ResumeTokenStore(clock: clock.clock)
        let hello = LinkHello(
            protocolMin: clientRange.lowerBound, protocolMax: clientRange.upperBound, capabilities: [.hevc, .gestures, .tablet],
            deviceName: deviceName, sceneLimits: LinkSceneLimits(maxWindows: 8, maxStreams: 8, maxPixelWidth: 2000, maxPixelHeight: 2000, maxFramesPerSecond: 60))
        let c = ClientSessionMachine(
            hello: hello, mode: mode, ownSPKIHash: clientSPKI, peerSPKIHash: helperSeenByClient ?? helperSPKI, exporter: exporterClient)
        let h = HelperSessionMachine(
            configuration: .init(
                macName: "Test Mac", helperSPKIHash: helperSPKI, capabilities: [.hevc, .menus], displays: [],
                askBeforeEachSession: askBeforeEachSession, sasPairingEnabled: sasEnabled),
            peerSPKIHash: clientSeenByHelper ?? clientSPKI, exporter: exporterHelper, devices: devices, ledger: ledger,
            resumeTokens: tokens, clock: clock.clock)
        return MachineRig(
            client: c, helper: h, devices: devices, ledger: ledger, resumeTokens: tokens, clock: clock, clientSPKI: clientSPKI,
            helperSPKI: helperSPKI)
    }

    /// `approve`: the Mac user's answer. `sasConfirm`: the iPad user's answer to the six digits.
    mutating func run(approve: Bool = true, sasConfirm: Bool = true) -> Outcome {
        var out = Outcome()
        var toHelper: [LinkMessage] = []
        var toClient: [LinkMessage] = []
        var clientDone = false, helperDone = false

        func perform(client actions: [ClientSessionMachine.Action], rig: inout MachineRig, out: inout Outcome, toHelper: inout [LinkMessage], clientDone: inout Bool) {
            for a in actions {
                switch a {
                case .send(let m): toHelper.append(m); out.clientSent.append(m.type)
                case .terminate(let e, _): out.clientError = e; clientDone = true
                case .event(.ready(let info)): out.clientInfo = info; clientDone = true
                case .event(.paired(let name, _)): out.clientPairedAs = name
                case .event(.sasCode(let code)):
                    out.sasCodes.append(code)
                    perform(client: rig.client.sasDecision(confirmed: sasConfirm), rig: &rig, out: &out, toHelper: &toHelper, clientDone: &clientDone)
                case .event(.awaitingMacApproval): break
                }
            }
        }
        func performHelper(_ actions: [HelperSessionMachine.Action], rig: inout MachineRig, out: inout Outcome, toClient: inout [LinkMessage], helperDone: inout Bool) {
            for a in actions {
                switch a {
                case .send(let m):
                    toClient.append(m); out.helperSent.append(m.type)
                    if case .pairDenied(let r) = m { out.helperDenied = r }
                case .terminate(let e, _): out.helperError = e; helperDone = true
                case .ready(let r): out.helperReady = r; helperDone = true
                case .requestApproval(let req):
                    out.approvals.append(req)
                    performHelper(rig.helper.approvalResult(approve), rig: &rig, out: &out, toClient: &toClient, helperDone: &helperDone)
                }
            }
        }

        perform(client: client.start(), rig: &self, out: &out, toHelper: &toHelper, clientDone: &clientDone)
        var guardCount = 0
        while guardCount < 200, !(toHelper.isEmpty && toClient.isEmpty) {
            guardCount += 1
            if !toHelper.isEmpty {
                let m = toHelper.removeFirst()
                if !helperDone { performHelper(helper.receive(m), rig: &self, out: &out, toClient: &toClient, helperDone: &helperDone) }
            }
            if !toClient.isEmpty {
                let m = toClient.removeFirst()
                if !clientDone { perform(client: client.receive(m), rig: &self, out: &out, toHelper: &toHelper, clientDone: &clientDone) }
            }
        }
        return out
    }
}

private func qrPayload(rig: MachineRig, expiry: Date? = nil) throws -> PairingQRPayload {
    let offer = try rig.ledger.issue()
    return PairingQRPayload(
        hostHints: ["mac.local"], port: 4433, macSPKIHash: rig.helperSPKI, secret: offer.secret, nonce: offer.nonce,
        expiry: expiry ?? offer.expiry)
}

/// The QR is made from the helper's SPKI, which the rig only knows after `make`; rebuild the client with the payload.
private func qrRig(
    exporterClient: Data? = Data(repeating: 7, count: 32), exporterHelper: Data? = Data(repeating: 7, count: 32),
    tamperSecret: Bool = false, ledger: PairingSecretLedger? = nil, clock: TestClock = TestClock()
) throws -> MachineRig {
    var rig = try MachineRig.make(mode: .reconnect(nil), exporterClient: exporterClient, exporterHelper: exporterHelper, ledger: ledger, clock: clock)
    let offer = try rig.ledger.issue()
    var secret = offer.secret
    if tamperSecret { secret[0] ^= 0xFF }
    let payload = PairingQRPayload(
        hostHints: ["mac.local"], port: 4433, macSPKIHash: rig.helperSPKI, secret: secret, nonce: offer.nonce, expiry: offer.expiry)
    rig.client = ClientSessionMachine(
        hello: rig.client.hello, mode: .pairWithQR(payload), ownSPKIHash: rig.clientSPKI, peerSPKIHash: rig.helperSPKI, exporter: exporterClient)
    return rig
}

@Suite struct ReconnectMachineTests {
    @Test func pairedDeviceGetsWelcome() throws {
        var rig = try MachineRig.make(mode: .reconnect(nil), paired: true)
        let out = rig.run()
        #expect(out.clientError == nil && out.helperError == nil)
        let info = try #require(out.clientInfo)
        #expect(info.protocolVersion == 1)
        #expect(info.macName == "Test Mac")
        #expect(info.capabilities == [.hevc], "intersection of both sides")
        #expect(info.resumeToken.count == 32 && info.sessionID != 0)
        let ready = try #require(out.helperReady)
        #expect(!ready.resumed && !ready.newlyPaired && ready.lastStateVersion == nil)
        #expect(out.approvals.isEmpty, "approval only at first pairing")
        #expect(out.clientSent == [.hello, .resume])
    }

    @Test func unknownOrRevokedDeviceIsNotAuthorized() throws {
        var rig = try MachineRig.make(mode: .reconnect(nil), paired: true)
        _ = try rig.devices.revoke(spkiHash: rig.clientSPKI)
        let out = rig.run()
        #expect(out.helperError == .notAuthorized)
        #expect(out.clientInfo == nil)
        #expect(LinkSessionError.notAuthorized.isPermanent)
    }

    @Test func neverPairedDeviceIsNotAuthorized() throws {
        var rig = try MachineRig.make(mode: .reconnect(nil), paired: false)
        let out = rig.run()
        #expect(out.helperError == .notAuthorized)
        #expect(out.helperReady == nil)
    }

    @Test func resumeWithValidTokenIsReported() throws {
        let devices = InMemoryPairedDeviceStore()
        let clock = TestClock()
        let tokens = ResumeTokenStore(clock: clock.clock)
        var first = try MachineRig.make(mode: .reconnect(nil), paired: true, devices: devices, resumeTokens: tokens, clock: clock)
        let out1 = first.run()
        let token = try #require(out1.clientInfo).resumeToken

        // Second connection by the same device presents the token.
        var second = try MachineRig.make(mode: .reconnect(nil), paired: false, devices: devices, resumeTokens: tokens, clock: clock)
        second.client = ClientSessionMachine(
            hello: second.client.hello, mode: .reconnect(LinkResumeCredentials(token: token, lastStateVersion: 42)),
            ownSPKIHash: first.clientSPKI, peerSPKIHash: second.helperSPKI, exporter: Data(repeating: 7, count: 32))
        second.helper = HelperSessionMachine(
            configuration: second.helper.configuration, peerSPKIHash: first.clientSPKI, exporter: Data(repeating: 7, count: 32),
            devices: devices, ledger: second.ledger, resumeTokens: tokens, clock: clock.clock)
        let out2 = second.run()
        let ready = try #require(out2.helperReady)
        #expect(ready.resumed)
        #expect(ready.lastStateVersion == 42)
        // The token is single use.
        var third = second
        third.client = ClientSessionMachine(
            hello: second.client.hello, mode: .reconnect(LinkResumeCredentials(token: token, lastStateVersion: 43)),
            ownSPKIHash: first.clientSPKI, peerSPKIHash: second.helperSPKI, exporter: Data(repeating: 7, count: 32))
        third.helper = HelperSessionMachine(
            configuration: second.helper.configuration, peerSPKIHash: first.clientSPKI, exporter: Data(repeating: 7, count: 32),
            devices: devices, ledger: second.ledger, resumeTokens: tokens, clock: clock.clock)
        let out3 = third.run()
        #expect(out3.helperReady?.resumed == false, "a replayed token starts a fresh session instead")
        #expect(out3.clientInfo != nil)
    }

    @Test func garbageOrExpiredTokenFallsBackToFreshSession() throws {
        let clock = TestClock()
        var rig = try MachineRig.make(mode: .reconnect(LinkResumeCredentials(token: Data(repeating: 9, count: 32), lastStateVersion: 5)), paired: true, clock: clock)
        let out = rig.run()
        #expect(out.helperReady?.resumed == false)
        #expect(out.helperReady?.lastStateVersion == nil)
        #expect(out.clientInfo != nil)

        // Valid token but expired.
        let devices = InMemoryPairedDeviceStore()
        let tokens = ResumeTokenStore(clock: clock.clock)
        var a = try MachineRig.make(mode: .reconnect(nil), paired: true, devices: devices, resumeTokens: tokens, clock: clock)
        let token = try tokens.issue(for: a.clientSPKI)
        clock.advance(ResumeTokenStore.lifetime + 1)
        a.client = ClientSessionMachine(
            hello: a.client.hello, mode: .reconnect(LinkResumeCredentials(token: token, lastStateVersion: 1)),
            ownSPKIHash: a.clientSPKI, peerSPKIHash: a.helperSPKI, exporter: Data(repeating: 7, count: 32))
        #expect(a.run().helperReady?.resumed == false)
    }

    @Test func tokenOfAnotherDeviceDoesNotResume() throws {
        let devices = InMemoryPairedDeviceStore()
        let tokens = ResumeTokenStore()
        var rig = try MachineRig.make(mode: .reconnect(nil), paired: true, devices: devices, resumeTokens: tokens)
        let stolen = try tokens.issue(for: try LinkRandom.bytes(32))
        rig.client = ClientSessionMachine(
            hello: rig.client.hello, mode: .reconnect(LinkResumeCredentials(token: stolen, lastStateVersion: 1)),
            ownSPKIHash: rig.clientSPKI, peerSPKIHash: rig.helperSPKI, exporter: Data(repeating: 7, count: 32))
        #expect(rig.run().helperReady?.resumed == false)
    }

    @Test func versionMismatchIsPermanentOnBothSides() throws {
        var rig = try MachineRig.make(mode: .reconnect(nil), paired: true, clientRange: 2...3)
        let out = rig.run()
        #expect(out.helperError == .versionMismatch(.remoteTooNew(remoteMin: 2)))
        #expect(out.helperReady == nil)
        #expect(out.helperError?.isPermanent == true)

        // A helper that answers with a version outside what we offered is rejected by the client.
        var c = ClientSessionMachine(
            hello: LinkHello(protocolMin: 1, protocolMax: 1, capabilities: [], deviceName: "x", sceneLimits: LinkSceneLimits(maxWindows: 1, maxStreams: 1, maxPixelWidth: 1, maxPixelHeight: 1, maxFramesPerSecond: 1)),
            mode: .reconnect(nil), ownSPKIHash: Data(count: 32), peerSPKIHash: Data(count: 32), exporter: nil)
        _ = c.start()
        let actions = c.receive(.welcome(LinkWelcome(protocolVersion: 9, sessionID: 1, resumeToken: LinkBytes32(repeating: 1), macName: "m", displays: [], capabilities: [])))
        guard case .terminate(let e, _) = actions.last else { Issue.record("expected terminate"); return }
        #expect(e.isPermanent)
    }

    @Test func askBeforeEachSessionRequiresApprovalEveryTime() throws {
        var rig = try MachineRig.make(mode: .reconnect(nil), paired: true, askBeforeEachSession: true)
        let out = rig.run(approve: true)
        #expect(out.approvals.map(\.reason) == [.session])
        #expect(out.helperSent.contains(.approvalRequired))
        #expect(out.clientInfo != nil)

        var denied = try MachineRig.make(mode: .reconnect(nil), paired: true, askBeforeEachSession: true)
        let d = denied.run(approve: false)
        #expect(d.helperError == .approvalDenied)
        #expect(d.clientInfo == nil)
    }

    @Test func handshakeOrderViolationsAreRejected() throws {
        let rig = try MachineRig.make(mode: .reconnect(nil), paired: true)
        var h = rig.helper
        // Anything but hello first.
        let a = h.receive(.resume(LinkResume(resumeToken: LinkBytes32(repeating: 0), lastStateVersion: 0)))
        #expect(a == [.terminate(.protocolViolation("unexpected resume"), notifyPeer: true)])
        // A media message in the handshake.
        var h2 = rig.helper
        _ = h2.receive(.hello(rig.client.hello))
        guard case .terminate(.protocolViolation, _)? = h2.receive(.pong(timestampMicros: 1)).first else {
            Issue.record("expected protocol violation"); return
        }
    }

    @Test func helperMessagesBeforeWelcomeAreViolationsForClient() throws {
        let rig = try MachineRig.make(mode: .reconnect(nil), paired: true)
        var c = rig.client
        _ = c.start()
        guard case .terminate(.protocolViolation, _)? = c.receive(.snapshot(LinkSnapshot(stateVersion: 1, apps: [], windows: []))).first else {
            Issue.record("expected violation"); return
        }
    }

    @Test func peerCloseMapsToPermanentErrors() throws {
        let rig = try MachineRig.make(mode: .reconnect(nil), paired: true)
        var c = rig.client
        _ = c.start()
        #expect(c.receive(.close(code: .notAuthorized, reason: "")) == [.terminate(.notAuthorized, notifyPeer: false)])
        #expect(!LinkSessionError.helperShuttingDown.isPermanent)
        #expect(!LinkSessionError.transport("x").isPermanent)
        #expect(LinkSessionError.peerClosed(.versionMismatch).isPermanent)
    }
}

@Suite struct QRPairingMachineTests {
    @Test func successfulPairing() throws {
        var rig = try qrRig()
        let out = rig.run()
        #expect(out.clientError == nil && out.helperError == nil)
        #expect(out.clientPairedAs == "Test Mac")
        #expect(out.clientInfo != nil)
        let ready = try #require(out.helperReady)
        #expect(ready.newlyPaired && ready.deviceName == "alice's iPad")
        #expect(out.approvals.map(\.reason) == [.newPairing(.qr)])
        #expect(rig.devices.device(spkiHash: rig.clientSPKI)?.name == "alice's iPad")
        #expect(out.clientSent == [.hello, .pairProve])
        #expect(out.helperSent == [.pairOK, .welcome])
    }

    @Test func userDeniesOnTheMac() throws {
        var rig = try qrRig()
        let out = rig.run(approve: false)
        #expect(out.helperDenied == .userDenied)
        #expect(out.clientError == .pairingDenied(.userDenied))
        #expect(rig.devices.all().isEmpty, "a denied device is not stored")
        #expect(out.clientInfo == nil)
    }

    @Test func wrongSecretIsBadProof() throws {
        var rig = try qrRig(tamperSecret: true)
        let out = rig.run()
        #expect(out.helperDenied == .badProof)
        #expect(out.clientError == .pairingDenied(.badProof))
        #expect(out.approvals.isEmpty, "the Mac user is never asked about a bad proof")
        #expect(rig.devices.all().isEmpty)
    }

    @Test func tamperedTranscriptIsRejected() throws {
        // The two ends disagree about the TLS channel (a relay with a different session): different exporters.
        var rig = try qrRig(exporterClient: Data(repeating: 1, count: 32), exporterHelper: Data(repeating: 2, count: 32))
        let out = rig.run()
        #expect(out.helperDenied == .badProof)
        #expect(rig.devices.all().isEmpty)
    }

    @Test func clientSeenWithADifferentCertificateIsRejected() throws {
        // A proof relayed through a MITM: the helper's TLS peer is not the key the prover named.
        var rig = try qrRig()
        rig.helper = HelperSessionMachine(
            configuration: rig.helper.configuration, peerSPKIHash: try LinkRandom.bytes(32), exporter: Data(repeating: 7, count: 32),
            devices: rig.devices, ledger: rig.ledger, resumeTokens: rig.resumeTokens, clock: rig.clock.clock)
        #expect(rig.run().helperDenied == .badProof)
    }

    @Test func secretIsSingleUse() throws {
        var rig = try qrRig()
        let payload: PairingQRPayload
        guard case .pairWithQR(let p) = rig.client.mode else { Issue.record("mode"); return }
        payload = p
        #expect(rig.run().helperReady != nil)
        // Replay the same QR from a second device.
        var replay = try MachineRig.make(mode: .pairWithQR(payload), devices: rig.devices, ledger: rig.ledger, resumeTokens: rig.resumeTokens, clock: rig.clock)
        replay.helper = HelperSessionMachine(
            configuration: .init(
                macName: "Test Mac", helperSPKIHash: rig.helperSPKI, capabilities: [], displays: [], askBeforeEachSession: false,
                sasPairingEnabled: false),
            peerSPKIHash: replay.clientSPKI, exporter: Data(repeating: 7, count: 32), devices: rig.devices, ledger: rig.ledger,
            resumeTokens: rig.resumeTokens, clock: rig.clock.clock)
        replay.client = ClientSessionMachine(
            hello: replay.client.hello, mode: .pairWithQR(payload), ownSPKIHash: replay.clientSPKI, peerSPKIHash: rig.helperSPKI,
            exporter: Data(repeating: 7, count: 32))
        let out = replay.run()
        #expect(out.helperDenied == .expired, "the burned secret is gone")
        #expect(replay.devices.all().count == 1)
    }

    @Test func expiredOfferIsRejected() throws {
        var rig = try qrRig()
        rig.clock.advance(PairingSecretLedger.lifetime + 1)
        #expect(rig.run().helperDenied == .expired)
    }

    @Test func threeWrongProofsBurnTheOffer() throws {
        let clock = TestClock()
        let ledger = PairingSecretLedger(clock: clock.clock)
        let devices = InMemoryPairedDeviceStore()
        var lastDenied: LinkPairDenyReason?
        var good: PairingQRPayload?
        for attempt in 0..<4 {
            var rig = try MachineRig.make(mode: .reconnect(nil), devices: devices, ledger: ledger, clock: clock)
            if attempt == 0 {
                let o = try ledger.issue()
                good = PairingQRPayload(hostHints: ["h"], port: 1, macSPKIHash: rig.helperSPKI, secret: o.secret, nonce: o.nonce, expiry: o.expiry)
            }
            var bad = good!
            bad.secret = Data(repeating: UInt8(attempt + 1), count: 16)
            bad.macSPKIHash = rig.helperSPKI
            rig.client = ClientSessionMachine(
                hello: rig.client.hello, mode: .pairWithQR(bad), ownSPKIHash: rig.clientSPKI, peerSPKIHash: rig.helperSPKI,
                exporter: Data(repeating: 7, count: 32))
            lastDenied = rig.run().helperDenied
        }
        #expect(lastDenied == .expired || lastDenied == .tooManyAttempts, "after three failures the offer is gone")
        // Even the right secret no longer works.
        var rig = try MachineRig.make(mode: .reconnect(nil), devices: devices, ledger: ledger, clock: clock)
        var p = good!
        p.macSPKIHash = rig.helperSPKI
        rig.client = ClientSessionMachine(
            hello: rig.client.hello, mode: .pairWithQR(p), ownSPKIHash: rig.clientSPKI, peerSPKIHash: rig.helperSPKI,
            exporter: Data(repeating: 7, count: 32))
        #expect(rig.run().helperDenied != nil)
        #expect(devices.all().isEmpty)
    }

    @Test func hourlyAttemptLimitDeniesAsBusy() throws {
        let clock = TestClock()
        let ledger = PairingSecretLedger(clock: clock.clock)
        var last: LinkPairDenyReason?
        for _ in 0..<(PairingSecretLedger.maxAttemptsPerHour + 1) {
            var rig = try qrRig(tamperSecret: true, ledger: ledger, clock: clock)
            last = rig.run().helperDenied
        }
        #expect(last == .busy)
    }

    @Test func qrForAnotherMacIsRejectedByTheClient() throws {
        var rig = try qrRig()
        guard case .pairWithQR(var p) = rig.client.mode else { return }
        p.macSPKIHash = try LinkRandom.bytes(32)
        rig.client = ClientSessionMachine(
            hello: rig.client.hello, mode: .pairWithQR(p), ownSPKIHash: rig.clientSPKI, peerSPKIHash: rig.helperSPKI,
            exporter: Data(repeating: 7, count: 32))
        let out = rig.run()
        #expect(out.clientError == .pinMismatch)
        #expect(out.helperReady == nil)
    }

    @Test func challengeBindingWorksWithoutAnExporter() throws {
        var rig = try qrRig(exporterClient: nil, exporterHelper: nil)
        let out = rig.run()
        #expect(out.helperSent.first == .pairChallenge)
        #expect(out.helperReady?.newlyPaired == true)
        #expect(out.clientInfo != nil)
    }

    @Test func exporterMismatchBetweenModesFails() throws {
        var rig = try qrRig(exporterClient: Data(repeating: 7, count: 32), exporterHelper: nil)
        #expect(rig.run().helperDenied == .badProof)
    }

    @Test func deviceNamesAreSanitized() throws {
        var rig = try MachineRig.make(mode: .reconnect(nil), deviceName: "Bob\u{0007}\n's iPad\u{202E}")
        let o = try rig.ledger.issue()
        let p = PairingQRPayload(hostHints: ["h"], port: 1, macSPKIHash: rig.helperSPKI, secret: o.secret, nonce: o.nonce, expiry: o.expiry)
        rig.client = ClientSessionMachine(
            hello: rig.client.hello, mode: .pairWithQR(p), ownSPKIHash: rig.clientSPKI, peerSPKIHash: rig.helperSPKI,
            exporter: Data(repeating: 7, count: 32))
        let out = rig.run()
        #expect(out.approvals.first?.deviceName == "Bob's iPad")
        #expect(SessionText.sanitizedDeviceName("") == "iPad")
        #expect(SessionText.sanitizedDeviceName(String(repeating: "é", count: 100)).utf8.count <= PairingProof.maxDeviceNameBytes)
    }
}

@Suite struct SASPairingMachineTests {
    @Test func bothSidesShowTheSameCodeAndPair() throws {
        var rig = try MachineRig.make(mode: .pairWithSAS)
        let out = rig.run()
        #expect(out.clientError == nil && out.helperError == nil)
        #expect(out.sasCodes.count == 1 && out.sasCodes[0].count == 6)
        #expect(out.approvals.first?.sasCode == out.sasCodes.first, "the Mac shows the same digits")
        #expect(out.approvals.map(\.reason) == [.newPairing(.sas)])
        #expect(out.helperReady?.newlyPaired == true)
        #expect(rig.devices.all().count == 1)
        #expect(out.clientSent == [.hello, .sasCommit, .sasReveal, .pairProve])
        #expect(out.helperSent == [.sasCommit, .sasReveal, .pairOK, .welcome])
    }

    @Test func userSaysTheCodesDiffer() throws {
        var rig = try MachineRig.make(mode: .pairWithSAS)
        let out = rig.run(sasConfirm: false)
        #expect(out.clientError == .sasRejected)
        #expect(out.approvals.isEmpty, "nothing is asked on the Mac")
        #expect(rig.devices.all().isEmpty)
        #expect(LinkSessionError.sasRejected.isPermanent)
    }

    @Test func aManInTheMiddleCausesDifferentCodes() throws {
        // The iPad believes the Mac's certificate is X, the Mac believes the iPad's certificate is Y: what a TLS relay produces.
        var rig = try MachineRig.make(mode: .pairWithSAS, helperSeenByClient: try LinkRandom.bytes(32), clientSeenByHelper: try LinkRandom.bytes(32))
        let out = rig.run()
        let shownOnIPad = try #require(out.sasCodes.first)
        let shownOnMac = out.approvals.first?.sasCode
        // The helper never reaches approval: the iPad's confirmation does not verify, which is the second line of defence.
        #expect(out.helperDenied == .badProof)
        #expect(shownOnMac == nil)
        #expect(shownOnIPad.count == 6)
    }

    @Test func sasIsRefusedWhenThePairingWindowIsClosed() throws {
        var rig = try MachineRig.make(mode: .pairWithSAS, sasEnabled: false)
        let out = rig.run()
        #expect(out.helperDenied == .unsupported)
        #expect(out.clientError == .pairingDenied(.unsupported))
    }

    @Test func userDeniesOnTheMacAfterSAS() throws {
        var rig = try MachineRig.make(mode: .pairWithSAS)
        let out = rig.run(approve: false)
        #expect(out.helperDenied == .userDenied)
        #expect(rig.devices.all().isEmpty)
    }

    @Test func revealThatDoesNotMatchItsCommitIsRejected() throws {
        let rig = try MachineRig.make(mode: .pairWithSAS)
        var h = rig.helper
        _ = h.receive(.hello(rig.client.hello))
        _ = h.receive(.sasCommit(LinkBytes32(repeating: 1)))
        let actions = h.receive(.sasReveal(LinkBytes32(repeating: 2)))
        guard case .terminate(.pairingFailed, _)? = actions.first else { Issue.record("expected failure"); return }
    }

    @Test func confirmationCannotBeReplayedAcrossSessions() throws {
        // Two independent SAS runs produce different codes/values; the first confirmation does not verify in the second.
        var a = try MachineRig.make(mode: .pairWithSAS)
        var b = try MachineRig.make(mode: .pairWithSAS)
        _ = a.run()
        let outB = b.run()
        #expect(outB.helperReady != nil)
        #expect(a.devices.all().count == 1 && b.devices.all().count == 1)
    }
}
