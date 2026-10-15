import Foundation
import LinkProtocol
import Testing
@testable import LinkTransport

private let transports: [LinkTransportKind] = [.quic, .tcp]

private func qrMode(_ server: LinkServer) async throws -> LinkClientMode {
    .pairWithQR(try await server.makePairingQRPayload(hostHints: ["127.0.0.1"]))
}

@Suite(.timeLimit(.minutes(1))) struct LoopbackTests {
    @Test(arguments: transports)
    func pairByQRThenReconnectWithPinAndResume(transport: LinkTransportKind) async throws {
        let rig = try LoopbackRig.make()
        let snapshot = LinkSnapshot(stateVersion: 7, apps: [], windows: [])
        let (server, ep) = try await rig.makeServer(snapshot: snapshot)
        let target = rig.endpoint(ep, transport: transport)

        // First contact: QR pairing, approved on the "Mac".
        let first = try await LinkConnection.connect(
            to: target, configuration: rig.clientConfiguration(mode: try await qrMode(server), transport: transport.preference))
        #expect(first.transport == transport)
        #expect(first.macSPKIHash == rig.helperSPKI)
        let paired = try #require(first.newlyPairedMac)
        #expect(paired.spkiHash == rig.helperSPKI && paired.name == "Test Mac")
        #expect(rig.macs.mac(forComputer: "mac-1") == paired, "the pin is stored for the saved computer")
        #expect(first.session.capabilities == [.hevc, .gestures])
        let requests = await rig.approvals.requests
        #expect(requests.count == 1 && requests[0].reason == .newPairing(.qr) && requests[0].deviceName == "Test iPad")
        #expect(rig.devices.device(spkiHash: rig.ipadSPKI)?.name == "Test iPad")

        // The helper gets the session, then the snapshot arrives on the control stream.
        var helperSessions = server.connections.makeAsyncIterator()
        let serverSide = try #require(await helperSessions.next())
        #expect(serverSide.session.newlyPaired && !serverSide.session.resumed)
        guard case .snapshot(let s)? = await nextElement(first.controlMessages) else { Issue.record("no snapshot"); return }
        #expect(s.stateVersion == 7)

        // Control messages both ways.
        try await first.send(.appsList(filter: .running))
        guard case .appsList(.running)? = await nextElement(serverSide.controlMessages) else { Issue.record("no appsList"); return }
        try await serverSide.send(.appsItems([]))
        guard case .appsItems(let items)? = await nextElement(first.controlMessages) else { Issue.record("no appsItems"); return }
        #expect(items.isEmpty)
        // Pings are answered by the channel itself.
        try await first.send(.ping(timestampMicros: 123))
        guard case .pong(123)? = await nextElement(first.controlMessages) else { Issue.record("no pong"); return }
        let token = first.session.resumeToken
        await first.close()
        #expect(await within(.seconds(5)) { await serverSide.waitUntilClosed() })
        #expect(await serverSide.failure == .closed, "a normal close from the iPad")

        // Reconnect with only the pin and the resume token: no new approval, session is reported as resumed.
        let creds = LinkResumeCredentials(token: token, lastStateVersion: 7)
        let second = try await LinkConnection.connect(
            to: target,
            configuration: rig.clientConfiguration(mode: .reconnect(creds), transport: transport.preference, pin: paired.spkiHash))
        #expect(second.newlyPairedMac == nil)
        let serverSide2 = try #require(await helperSessions.next())
        #expect(serverSide2.session.resumed && serverSide2.session.lastStateVersion == 7)
        guard case .snapshot? = await nextElement(second.controlMessages) else { Issue.record("no snapshot after resume"); return }
        #expect(await rig.approvals.requests.count == 1, "paired devices connect without a prompt")
        #expect(second.session.resumeToken != token)

        await second.close()
        await rig.tearDown()
    }

    @Test(arguments: transports)
    func pairBySASWhenThePairingWindowIsOpen(transport: LinkTransportKind) async throws {
        let rig = try LoopbackRig.make()
        let (_, ep) = try await rig.makeServer()
        let target = rig.endpoint(ep, transport: transport)

        // Window closed: refused, permanently.
        do {
            _ = try await LinkConnection.connect(
                to: target, configuration: rig.clientConfiguration(mode: .pairWithSAS, transport: transport.preference, sas: { _ in true }))
            Issue.record("pairing should be refused")
        } catch let e as LinkSessionError {
            #expect(e == .pairingDenied(.unsupported) && e.isPermanent)
        }

        rig.sasPairingOpen = true
        let shown = Shown()
        let conn = try await LinkConnection.connect(
            to: target,
            configuration: rig.clientConfiguration(mode: .pairWithSAS, transport: transport.preference, sas: { code in await shown.set(code); return true }))
        let request = try #require(await rig.approvals.requests.last)
        #expect(request.reason == .newPairing(.sas))
        #expect(request.sasCode == (await shown.code), "both screens show the same six digits")
        #expect(conn.newlyPairedMac != nil)
        await conn.close()
        await rig.tearDown()
    }

    @Test(arguments: transports)
    func userDeniesOnTheMacAndSASMismatchIsReported(transport: LinkTransportKind) async throws {
        let rig = try LoopbackRig.make()
        let (server, ep) = try await rig.makeServer()
        let target = rig.endpoint(ep, transport: transport)
        await rig.approvals.setAnswer(false)
        do {
            _ = try await LinkConnection.connect(
                to: target, configuration: rig.clientConfiguration(mode: try await qrMode(server), transport: transport.preference))
            Issue.record("should be denied")
        } catch let e as LinkSessionError {
            #expect(e == .pairingDenied(.userDenied) && e.isPermanent)
        }
        #expect(rig.devices.all().isEmpty)

        rig.sasPairingOpen = true
        do {
            _ = try await LinkConnection.connect(
                to: target, configuration: rig.clientConfiguration(mode: .pairWithSAS, transport: transport.preference, sas: { _ in false }))
            Issue.record("should be rejected")
        } catch let e as LinkSessionError {
            #expect(e == .sasRejected)
        }
        #expect(await rig.approvals.requests.count == 1, "the Mac was only asked about the QR attempt")
        await rig.tearDown()
    }

    @Test(arguments: transports)
    func unknownRevokedAndMispinnedPeersAreRefused(transport: LinkTransportKind) async throws {
        let rig = try LoopbackRig.make()
        let (server, ep) = try await rig.makeServer()
        let target = rig.endpoint(ep, transport: transport)

        // Never paired.
        do {
            _ = try await LinkConnection.connect(
                to: target, configuration: rig.clientConfiguration(mode: .reconnect(nil), transport: transport.preference, pin: rig.helperSPKI))
            Issue.record("unpaired device must be refused")
        } catch let e as LinkSessionError {
            #expect(e == .notAuthorized && e.isPermanent)
        }

        // Pair, then revoke while connected: the live session ends with notAuthorized, and a new attempt is refused.
        let conn = try await LinkConnection.connect(
            to: target, configuration: rig.clientConfiguration(mode: try await qrMode(server), transport: transport.preference))
        let removed = try await server.revoke(deviceSPKIHash: rig.ipadSPKI)
        #expect(removed)
        #expect(await within(.seconds(5)) { await conn.waitUntilClosed() })
        #expect(await conn.failure == .notAuthorized)
        do {
            _ = try await LinkConnection.connect(
                to: target, configuration: rig.clientConfiguration(mode: .reconnect(nil), transport: transport.preference, pin: rig.helperSPKI))
            Issue.record("revoked device must be refused")
        } catch let e as LinkSessionError { #expect(e == .notAuthorized) }

        // A client pinned to some other key never completes TLS.
        do {
            _ = try await LinkConnection.connect(
                to: target,
                configuration: rig.clientConfiguration(mode: .reconnect(nil), transport: transport.preference, pin: Data(repeating: 9, count: 32)))
            Issue.record("wrong pin must fail")
        } catch let e as LinkSessionError {
            #expect(e == .pinMismatch && e.isPermanent)
        }
        await rig.tearDown()
    }

    @Test(arguments: transports)
    func threeWindowStreamsCarryFramedDataConcurrently(transport: LinkTransportKind) async throws {
        let rig = try LoopbackRig.make()
        let (server, ep) = try await rig.makeServer()
        let target = rig.endpoint(ep, transport: transport)
        let client = try await LinkConnection.connect(
            to: target, configuration: rig.clientConfiguration(mode: try await qrMode(server), transport: transport.preference))
        var it = server.connections.makeAsyncIterator()
        let helper = try #require(await it.next())
        let clientEvents = EventLog(client.events)

        let windows: [WindowID] = [10, 20, 30]
        let framesPerWindow = 12
        let frameBytes = 150_000
        await withTaskGroup(of: Void.self) { group in
            for w in windows {
                group.addTask {
                    try? await helper.send(.videoConfig(LinkVideoConfig(
                        window: w, codec: .hevc, parameterSets: [Data([1, 2, 3])], pixelWidth: 100, pixelHeight: 100,
                        contentRect: LinkRect(x: 0, y: 0, width: 100, height: 100), scale: 2)))
                    for i in 0..<framesPerWindow {
                        let payload = Data(repeating: UInt8(truncatingIfNeeded: Int(w.rawValue) + i), count: frameBytes)
                        try? await helper.send(.videoFrame(LinkVideoFrame(
                            window: w, sequence: UInt32(i), ptsMicros: UInt64(i) * 16_000, flags: i == 0 ? [.key] : [], data: payload)))
                    }
                }
            }
        }
        for w in windows {
            let opened = await clientEvents.wait { if case .streamOpened(.window(w), _) = $0 { true } else { false } }
            guard case .streamOpened(_, let inbox)? = opened else { Issue.record("stream for \(w) never opened"); return }
            guard case .videoConfig(let cfg)? = await nextElement(inbox) else { Issue.record("no config"); return }
            #expect(cfg.window == w)
            for i in 0..<framesPerWindow {
                guard case .videoFrame(let f)? = await nextElement(inbox) else { Issue.record("missing frame \(i) of \(w)"); return }
                #expect(f.window == w && f.sequence == UInt32(i), "frames of one window arrive in order")
                #expect(f.data.count == frameBytes && f.data.first == UInt8(truncatingIfNeeded: Int(w.rawValue) + i))
            }
        }
        // Finishing one window stream is reported; the others keep working.
        await helper.finishWindowStream(10)
        let finished = await clientEvents.wait { if case .streamFinished(.window(10)) = $0 { true } else { false } }
        #expect(finished != nil)
        try await helper.send(.videoFrame(LinkVideoFrame(window: 20, sequence: 99, ptsMicros: 0, flags: [.key], data: Data([1]))))
        let opened20 = await clientEvents.wait { if case .streamOpened(.window(20), _) = $0 { true } else { false } }
        guard case .streamOpened(_, let inbox20)? = opened20 else { Issue.record("window 20 stream missing"); return }
        guard case .videoFrame(let extra)? = await nextElement(inbox20) else { Issue.record("no frame after sibling closed"); return }
        #expect(extra.sequence == 99)
        await client.close()
        await rig.tearDown()
    }

    @Test(arguments: transports)
    func inputIsCoalescedButEdgesAreKept(transport: LinkTransportKind) async throws {
        let rig = try LoopbackRig.make()
        let (server, ep) = try await rig.makeServer()
        let target = rig.endpoint(ep, transport: transport)
        let client = try await LinkConnection.connect(
            to: target, configuration: rig.clientConfiguration(mode: try await qrMode(server), transport: transport.preference))
        var it = server.connections.makeAsyncIterator()
        let helper = try #require(await it.next())
        let helperEvents = EventLog(helper.events)

        func pointer(_ x: Double, _ buttons: LinkMouseButtons) -> LinkMessage {
            .inputPointer(LinkPointerEvent(window: 3, point: LinkPoint(x: x, y: 1), buttons: buttons, modifiers: []))
        }
        for x in 0..<500 { try await client.send(pointer(Double(x), [])) }
        try await client.send(pointer(500, .left))
        for x in 501..<900 { try await client.send(pointer(Double(x), .left)) }
        try await client.send(pointer(900, []))
        try await client.send(.inputText("end"))

        let opened = await helperEvents.wait { if case .streamOpened(.input, _) = $0 { true } else { false } }
        guard case .streamOpened(_, let inbox)? = opened else { Issue.record("input stream never opened"); return }
        var received: [LinkMessage] = []
        while let m = await nextElement(inbox) {
            received.append(m)
            if case .inputText("end") = m { break }
        }
        let pointers = received.compactMap { m -> LinkPointerEvent? in if case .inputPointer(let p) = m { p } else { nil } }
        #expect(pointers.count < 900, "moves were merged while the link was busy (or at least not inflated)")
        #expect(pointers.contains { $0.point.x == 500 && $0.buttons == .left }, "press edge delivered")
        #expect(pointers.contains { $0.point.x == 900 && $0.buttons.isEmpty }, "release edge delivered")
        let lastDrag = pointers.last { $0.buttons == .left }
        #expect(lastDrag?.point.x == 899, "the final position of the drag is the latest one")
        // Order of edges is preserved.
        let pressIndex = pointers.firstIndex { $0.point.x == 500 }
        let releaseIndex = pointers.firstIndex { $0.point.x == 900 }
        #expect((pressIndex ?? 0) < (releaseIndex ?? 0))
        await client.close()
        await rig.tearDown()
    }

    @Test(arguments: transports)
    func closeCodesReachThePeer(transport: LinkTransportKind) async throws {
        let rig = try LoopbackRig.make()
        let (server, ep) = try await rig.makeServer()
        let target = rig.endpoint(ep, transport: transport)
        let client = try await LinkConnection.connect(
            to: target, configuration: rig.clientConfiguration(mode: try await qrMode(server), transport: transport.preference))
        var it = server.connections.makeAsyncIterator()
        let helper = try #require(await it.next())

        await helper.close(code: .helperShuttingDown, reason: "bye")
        #expect(await within(.seconds(5)) { await client.waitUntilClosed() })
        #expect(await client.failure == .helperShuttingDown)
        #expect(LinkSessionError.helperShuttingDown.isPermanent == false, "the app may reconnect")

        // A second connection from the same device replaces an existing one.
        let a = try await LinkConnection.connect(
            to: target, configuration: rig.clientConfiguration(mode: .reconnect(nil), transport: transport.preference, pin: rig.helperSPKI))
        _ = await it.next()
        let b = try await LinkConnection.connect(
            to: target, configuration: rig.clientConfiguration(mode: .reconnect(nil), transport: transport.preference, pin: rig.helperSPKI))
        #expect(await within(.seconds(5)) { await a.waitUntilClosed() })
        #expect(await a.failure == .sessionReplaced)
        await b.close(code: .normal)
        await rig.tearDown()
    }

    /// Network.framework gives the server one extra, silent `NWConnection` per QUIC connection. Cancelling it (for example
    /// because it "never sent a preamble") used to tear the whole connection down ten seconds after the handshake.
    @Test func quicConnectionSurvivesTheSilentExtraStreamPastThePreambleTimeout() async throws {
        let saved = QUICWire.preambleTimeout
        QUICWire.preambleTimeout = .milliseconds(300)
        defer { QUICWire.preambleTimeout = saved }
        let rig = try LoopbackRig.make()
        let (server, ep) = try await rig.makeServer(enableTCP: false)
        let client = try await LinkConnection.connect(
            to: rig.endpoint(ep, transport: .quic),
            configuration: rig.clientConfiguration(mode: try await qrMode(server), transport: .quic))
        try await Task.sleep(for: .milliseconds(800))
        try await client.send(.ping(timestampMicros: 9))
        guard case .pong(9)? = await nextElement(client.controlMessages) else { Issue.record("connection died after the preamble timeout"); return }
        await client.close()
        await rig.tearDown()
    }

    @Test func automaticTransportFallsBackToTCPWhenQUICIsUnavailable() async throws {
        let rig = try LoopbackRig.make()
        let (server, ep) = try await rig.makeServer(enableQUIC: false)
        // Without a QUIC listener nothing answers on the UDP port: the client gives up on QUIC and uses TCP.
        let port = try #require(ep.tcpPort)
        let conn = try await LinkConnection.connect(
            to: LinkEndpoint(host: "127.0.0.1", port: port),
            configuration: rig.clientConfiguration(mode: try await qrMode(server), transport: .automatic, quicTimeout: .seconds(1)))
        #expect(conn.transport == .tcp)
        try await conn.send(.ping(timestampMicros: 1))
        guard case .pong? = await nextElement(conn.controlMessages) else { Issue.record("no pong over the fallback"); return }
        await conn.close()

        // Both available: automatic prefers QUIC.
        let rig2 = try LoopbackRig.make()
        let (server2, ep2) = try await rig2.makeServer()
        let c2 = try await LinkConnection.connect(
            to: rig2.endpoint(ep2, transport: .quic),
            configuration: rig2.clientConfiguration(mode: try await qrMode(server2), transport: .automatic))
        #expect(c2.transport == .quic)
        await c2.close()
        await rig.tearDown()
        await rig2.tearDown()
    }

    @Test(arguments: transports)
    func askBeforeEachSessionPromptsPairedDevices(transport: LinkTransportKind) async throws {
        let rig = try LoopbackRig.make()
        let (server, ep) = try await rig.makeServer(askBeforeEachSession: true)
        let target = rig.endpoint(ep, transport: transport)
        let first = try await LinkConnection.connect(
            to: target, configuration: rig.clientConfiguration(mode: try await qrMode(server), transport: transport.preference))
        await first.close()
        let before = await rig.approvals.requests.count
        let second = try await LinkConnection.connect(
            to: target, configuration: rig.clientConfiguration(mode: .reconnect(nil), transport: transport.preference, pin: rig.helperSPKI))
        #expect(await rig.approvals.requests.count == before + 1)
        #expect(await rig.approvals.requests.last?.reason == .session)
        await second.close()
        await rig.approvals.setAnswer(false)
        do {
            _ = try await LinkConnection.connect(
                to: target, configuration: rig.clientConfiguration(mode: .reconnect(nil), transport: transport.preference, pin: rig.helperSPKI))
            Issue.record("declined session must fail")
        } catch let e as LinkSessionError {
            #expect(e == .approvalDenied && e.isPermanent)
        }
        await rig.tearDown()
    }
}

actor Shown {
    private(set) var code: String?
    func set(_ c: String) { code = c }
}
