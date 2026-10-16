import Foundation
import LinkProtocol
import Testing
@testable import LinkTransport

/// `maxSessions` is enforced before `welcome`, in the same step as the admission: a device that does not fit is never welcomed.
@Suite(.timeLimit(.minutes(1))) struct SessionLimitTests {
    private func pairFirstDevice(_ rig: LoopbackRig, _ server: LinkServer, _ target: LinkEndpoint) async throws -> LinkConnection {
        let qr = LinkClientMode.pairWithQR(try await server.makePairingQRPayload(hostHints: ["127.0.0.1"]))
        return try await LinkConnection.connect(to: target, configuration: rig.clientConfiguration(mode: qr, transport: .tcp))
    }

    @Test func aPairedDeviceOverTheLimitIsRefusedBeforeWelcome() async throws {
        let rig = try LoopbackRig.make()
        let (server, ep) = try await rig.makeServer(enableQUIC: false, maxSessions: 1)
        let target = rig.endpoint(ep, transport: .tcp)
        let first = try await pairFirstDevice(rig, server, target)

        let (second, secondSec) = try rig.makeExtraIPad()
        try rig.devices.add(PairedDevice(spkiHash: second.spkiHash, name: "second iPad", pairedAt: Date()))
        let config = rig.clientConfiguration(mode: .reconnect(nil), transport: .tcp, pin: rig.helperSPKI, identity: secondSec)
        do {
            let c = try await LinkConnection.connect(to: target, configuration: config)
            Issue.record("the second device was welcomed")
            await c.close()
        } catch let error as LinkSessionError {
            #expect(error == .peerClosed(.tooManySessions), "refused with a proper close code, got \(error)")
        }
        #expect(await server.activeSessions.count == 1)
        #expect(await server.activeSessions.first?.deviceSPKIHash == rig.ipadSPKI, "the first session is untouched")
        await first.close()
        await rig.tearDown()
    }

    @Test func theSameDeviceMayReplaceItsOwnSessionWhenFull() async throws {
        let rig = try LoopbackRig.make()
        let (server, ep) = try await rig.makeServer(enableQUIC: false, maxSessions: 1)
        let target = rig.endpoint(ep, transport: .tcp)
        let first = try await pairFirstDevice(rig, server, target)
        let again = try await LinkConnection.connect(
            to: target, configuration: rig.clientConfiguration(mode: .reconnect(nil), transport: .tcp, pin: rig.helperSPKI))
        await first.waitUntilClosed()
        #expect(await server.activeSessions.count == 1)
        await again.close()
        await rig.tearDown()
    }

    @Test func aNewPairingOverTheLimitIsDeniedBusyAndNotStored() async throws {
        let rig = try LoopbackRig.make()
        let (server, ep) = try await rig.makeServer(enableQUIC: false, maxSessions: 1)
        let target = rig.endpoint(ep, transport: .tcp)
        let first = try await pairFirstDevice(rig, server, target)

        let (second, secondSec) = try rig.makeExtraIPad()
        let qr = LinkClientMode.pairWithQR(try await server.makePairingQRPayload(hostHints: ["127.0.0.1"]))
        let config = rig.clientConfiguration(mode: qr, transport: .tcp, identity: secondSec)
        do {
            let c = try await LinkConnection.connect(to: target, configuration: config)
            Issue.record("the second device was paired and welcomed")
            await c.close()
        } catch let error as LinkSessionError {
            #expect(error == .pairingDenied(.busy), "got \(error)")
        }
        #expect(rig.devices.device(spkiHash: second.spkiHash) == nil, "a refused pairing is not stored")
        await first.close()
        await rig.tearDown()
    }
}
