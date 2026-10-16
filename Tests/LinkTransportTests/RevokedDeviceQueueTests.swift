import Foundation
import LinkProtocol
import Testing
@testable import LinkTransport

/// A revoked device must not act on what it queued before the revoke.
@Suite(.timeLimit(.minutes(1))) struct RevokedDeviceQueueTests {
    @Test func revokeDiscardsInputTheDeviceQueuedBeforeIt() async throws {
        let rig = try LoopbackRig.make()
        let (server, ep) = try await rig.makeServer(enableQUIC: false)
        let target = rig.endpoint(ep, transport: .tcp)
        let payload = try await server.makePairingQRPayload(hostHints: ["127.0.0.1"])
        let client = try await LinkConnection.connect(
            to: target, configuration: rig.clientConfiguration(mode: .pairWithQR(payload), transport: .tcp))
        var it = server.connections.makeAsyncIterator()
        let helper = try #require(await it.next())
        let events = EventLog(helper.events)

        // The device queues input; the helper has not read any of it yet.
        for i in 0..<20 { try await client.send(.inputText("queued \(i)")) }
        let opened = await events.wait { if case .streamOpened(.input, _) = $0 { true } else { false } }
        guard case .streamOpened(_, let inbox)? = opened else { Issue.record("input stream never opened"); return }
        try await Task.sleep(for: .milliseconds(300))

        _ = try await server.revoke(deviceSPKIHash: rig.ipadSPKI)
        _ = await events.wait { $0.closedError != nil }

        var delivered = 0
        for await _ in inbox { delivered += 1 }
        #expect(delivered == 0, "input queued before the revoke must not reach the helper's session afterwards")
        await client.close()
        await rig.tearDown()
    }
}
