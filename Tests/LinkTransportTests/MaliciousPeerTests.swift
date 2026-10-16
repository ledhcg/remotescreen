import Foundation
import LinkProtocol
import Testing
@testable import LinkTransport

/// A hostile iPad: a TLS-authenticated peer (any well-formed certificate gets that far) that then misbehaves. The helper must
/// close the connection and stay healthy for the next, legitimate client. No test here may crash or hang.
@Suite(.timeLimit(.minutes(1))) struct MaliciousPeerTests {
    private let transports: [LinkTransportKind] = [.quic, .tcp]

    private func rawWire(_ transport: LinkTransportKind, _ rig: LoopbackRig, _ ep: LinkServerEndpoint) async throws -> any LinkWire {
        let target = rig.endpoint(ep, transport: transport)
        let wire: any LinkWire = transport == .quic
            ? QUICWire(endpoint: target.quic, identity: rig.ipadSec, policy: .pairing)
            : TCPMuxWire(endpoint: target.tcp, identity: rig.ipadSec, policy: .pairing)
        try await wire.start(timeout: .seconds(5))
        return wire
    }

    /// The server must end this stream/connection promptly.
    private func serverHangsUp(_ stream: any LinkWireStream) async -> Bool {
        await within(.seconds(5)) { while (try? await stream.read()) != nil {} }
    }

    /// A legitimate client can still pair afterwards.
    private func serverStillWorks(_ rig: LoopbackRig, _ server: LinkServer, _ ep: LinkServerEndpoint, _ transport: LinkTransportKind) async throws {
        let payload = try await server.makePairingQRPayload(hostHints: ["127.0.0.1"])
        let conn = try await LinkConnection.connect(
            to: rig.endpoint(ep, transport: transport),
            configuration: rig.clientConfiguration(mode: .pairWithQR(payload), transport: transport.preference))
        try await conn.send(.ping(timestampMicros: 5))
        guard case .pong(5)? = await nextElement(conn.controlMessages) else { Issue.record("server unhealthy after attack"); return }
        await conn.close()
    }

    private func le32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: v >> (8 * UInt32($0))) } }
    private func header(type: UInt16, length: UInt32) -> Data { Data([UInt8(type & 0xFF), UInt8(type >> 8)] + le32(length)) }

    @Test func garbageBeforeHelloClosesTheConnection() async throws {
        for transport in transports {
            let rig = try LoopbackRig.make()
            let (server, ep) = try await rig.makeServer()
            let wire = try await rawWire(transport, rig, ep)
            let stream = try await wire.openStream(.control)
            try await stream.write(Data((0..<200).map { UInt8(truncatingIfNeeded: $0 &* 37 &+ 11) }))
            #expect(await serverHangsUp(stream), "\(transport): garbage must end the connection")
            wire.close()
            #expect(await server.activeSessions.isEmpty)
            try await serverStillWorks(rig, server, ep, transport)
            await rig.tearDown()
        }
    }

    @Test func oversizedAndUnknownFramesCloseTheConnection() async throws {
        for transport in transports {
            let rig = try LoopbackRig.make()
            let (server, ep) = try await rig.makeServer()
            let attacks: [(String, Data)] = [
                ("4 GiB hello", header(type: LinkMessageType.hello.rawValue, length: 0xFFFF_FFFF)),
                ("oversized ping", header(type: LinkMessageType.ping.rawValue, length: UInt32(LinkLimits.maxControlMessageBytes + 1))),
                ("unknown mandatory type", header(type: 0x0777, length: 4) + Data(repeating: 0, count: 4)),
                ("ignorable but huge", header(type: 0x8001, length: UInt32(LinkLimits.maxIgnorablePayloadBytes + 1))),
                ("valid ping before hello", try LinkFrameEncoder.encode(.ping(timestampMicros: 1))),
                ("server message sent by client", try LinkFrameEncoder.encode(.pairOK(LinkPairOK(macName: "x", helperID: LinkBytes32(repeating: 1))))),
            ]
            for (name, bytes) in attacks {
                let wire = try await rawWire(transport, rig, ep)
                let stream = try await wire.openStream(.control)
                try await stream.write(bytes)
                #expect(await serverHangsUp(stream), "\(transport): \(name)")
                wire.close()
            }
            #expect(await server.activeSessions.isEmpty)
            try await serverStillWorks(rig, server, ep, transport)
            await rig.tearDown()
        }
    }

    @Test func malformedHelloBodyIsRejected() async throws {
        let rig = try LoopbackRig.make()
        let (server, ep) = try await rig.makeServer()
        // A hello with a truncated body (declared 100 bytes, 3 sent, then the stream finishes): decoder never completes it.
        let wire = try await rawWire(.quic, rig, ep)
        let stream = try await wire.openStream(.control)
        try await stream.write(header(type: LinkMessageType.hello.rawValue, length: 100) + Data([1, 2, 3]))
        await stream.finish()
        #expect(await serverHangsUp(stream))
        // A complete frame with a body that is not a hello.
        let wire2 = try await rawWire(.quic, rig, ep)
        let s2 = try await wire2.openStream(.control)
        try await s2.write(header(type: LinkMessageType.hello.rawValue, length: 3) + Data([0xFF, 0xFF, 0xFF]))
        #expect(await serverHangsUp(s2))
        wire.close(); wire2.close()
        try await serverStillWorks(rig, server, ep, .quic)
        await rig.tearDown()
    }

    @Test func tcpMuxViolationsCloseTheConnection() async throws {
        let rig = try LoopbackRig.make()
        let (server, ep) = try await rig.makeServer()
        func attack(_ name: String, _ body: @escaping @Sendable (TCPMuxWire) async throws -> Void) async throws {
            let target = rig.endpoint(ep, transport: .tcp)
            let wire = TCPMuxWire(endpoint: target.tcp, identity: rig.ipadSec, policy: .pairing)
            try await wire.start(timeout: .seconds(5))
            try? await body(wire)
            #expect(await within(.seconds(5)) { await wire.waitUntilClosed() }, "\(name): server must drop the connection")
            wire.close()
        }
        try await attack("data for an unknown stream id") { w in try await w.sendFrame(.data(streamID: 99, Data([1, 2, 3]))) }
        try await attack("open with the helper's id parity") { w in try await w.sendFrame(.open(streamID: 2, kind: .control)) }
        try await attack("open of a helper-only kind") { w in try await w.sendFrame(.open(streamID: 1, kind: .window(4))) }
        try await attack("reused stream id") { w in
            try await w.sendFrame(.open(streamID: 3, kind: .control))
            try await w.sendFrame(.open(streamID: 3, kind: .input))
        }
        try await attack("decreasing stream id") { w in
            try await w.sendFrame(.open(streamID: 5, kind: .control))
            try await w.sendFrame(.open(streamID: 3, kind: .input))
        }
        try await attack("duplicate control stream") { w in
            try await w.sendFrame(.open(streamID: 1, kind: .control))
            try await w.sendFrame(.open(streamID: 3, kind: .control))
        }
        try await attack("data after fin") { w in
            try await w.sendFrame(.open(streamID: 1, kind: .control))
            try await w.sendFrame(.fin(streamID: 1))
            try await w.sendFrame(.data(streamID: 1, Data([1])))
        }
        try await attack("too many concurrent streams") { w in
            for i in 0..<(LinkMux.maxOpenStreamsPerSide + 2) { try await w.sendFrame(.open(streamID: UInt32(2 * i + 1), kind: .input)) }
        }
        try await serverStillWorks(rig, server, ep, .tcp)
        await rig.tearDown()
    }

    @Test func quicStreamViolationsCloseTheConnection() async throws {
        let rig = try LoopbackRig.make()
        let (server, ep) = try await rig.makeServer()
        func attack(_ name: String, _ body: @escaping @Sendable (QUICWire) async throws -> (any LinkWireStream)?) async throws {
            let target = rig.endpoint(ep, transport: .quic)
            let wire = QUICWire(endpoint: target.quic, identity: rig.ipadSec, policy: .pairing)
            try await wire.start(timeout: .seconds(5))
            _ = try? await body(wire)
            #expect(await within(.seconds(5)) { await wire.waitUntilClosed() }, "\(name): server must drop the connection")
            wire.close()
        }
        try await attack("invalid preamble") { w in
            try await w.openRawStream(preamble: Data([0xEE, 1, 2, 3]), bidirectional: true, kind: .control)
        }
        try await attack("window stream opened by the client") { w in try await w.openStream(.window(7)) }
        try await attack("audio stream opened by the client") { w in try await w.openStream(.audio) }
        try await attack("duplicate input stream") { w in
            _ = try await w.openStream(.input)
            return try await w.openStream(.input)
        }
        try await serverStillWorks(rig, server, ep, .quic)
        await rig.tearDown()
    }

    @Test(arguments: [LinkTransportKind.quic, .tcp])
    func authenticatedPeerMisbehavingAfterTheHandshake(transport: LinkTransportKind) async throws {
        let rig = try LoopbackRig.make()
        let (server, ep) = try await rig.makeServer()
        var it = server.connections.makeAsyncIterator()
        let attacks: [(String, Data)] = [
            ("input message on the control stream", try LinkFrameEncoder.encode(.inputText("hi"))),
            ("helper-only message", try LinkFrameEncoder.encode(.snapshot(LinkSnapshot(stateVersion: 1, apps: [], windows: [])))),
            ("second hello", try LinkFrameEncoder.encode(.hello(LinkHello(
                protocolMin: 1, protocolMax: 1, capabilities: [], deviceName: "x",
                sceneLimits: LinkSceneLimits(maxWindows: 1, maxStreams: 1, maxPixelWidth: 1, maxPixelHeight: 1, maxFramesPerSecond: 1))))),
            ("oversized frame header", header(type: LinkMessageType.clipboardData.rawValue, length: UInt32(LinkLimits.maxClipboardBytes + 2048))),
            ("garbage", Data(repeating: 0xA5, count: 64)),
        ]
        for (i, (name, bytes)) in attacks.enumerated() {
            let payload = try await server.makePairingQRPayload(hostHints: ["127.0.0.1"])
            let conn = try await LinkConnection.connect(
                to: rig.endpoint(ep, transport: transport),
                configuration: rig.clientConfiguration(
                    mode: i == 0 ? .pairWithQR(payload) : .reconnect(nil), transport: transport.preference,
                    pin: i == 0 ? nil : rig.helperSPKI))
            let helper = try #require(await it.next())
            try await conn.channel.writeRawForTesting(bytes, on: .control)
            #expect(await within(.seconds(5)) { await helper.waitUntilClosed() }, "\(transport): \(name)")
            guard case .protocolViolation? = await helper.failure else {
                Issue.record("\(transport): \(name): expected a protocol violation, got \(String(describing: await helper.failure))")
                continue
            }
            // The offender is told why.
            #expect(await within(.seconds(5)) { await conn.waitUntilClosed() })
            await conn.close()
        }
        #expect(await server.activeSessions.isEmpty)
        await rig.tearDown()
    }

    @Test func silentConnectionsAreDroppedAndDoNotExhaustTheServer() async throws {
        let rig = try LoopbackRig.make()
        let config = LinkServerConfiguration(
            identity: rig.helperSec, macName: "Test Mac", capabilities: [], pairedDevices: rig.devices,
            approvalHandler: { _ in true }, handshakeTimeout: .seconds(1), loopbackOnly: true, maxPendingConnections: 2)
        let server = try LinkServer(configuration: config)
        let ep = try await server.start()
        let target = LinkEndpoint(host: "127.0.0.1", port: ep.tcpPort ?? 0)
        // Two silent clients take both slots; they open no stream at all.
        var silent: [TCPMuxWire] = []
        for _ in 0..<2 {
            let w = TCPMuxWire(endpoint: target.tcp, identity: rig.ipadSec, policy: .pairing)
            try await w.start(timeout: .seconds(5))
            silent.append(w)
        }
        // Slot holders are cut after the handshake timeout.
        for w in silent { #expect(await within(.seconds(5)) { await w.waitUntilClosed() }, "silent connection must be dropped") }
        // And then a real client gets in.
        let payload = try await server.makePairingQRPayload(hostHints: ["127.0.0.1"])
        let conn = try await LinkConnection.connect(
            to: target, configuration: rig.clientConfiguration(mode: .pairWithQR(payload), transport: .tcp))
        await conn.close()
        await server.stop()
        await rig.tearDown()
    }

    @Test func oneHostCannotHoldEveryHandshakeSlot() async throws {
        let rig = try LoopbackRig.make()
        let config = LinkServerConfiguration(
            identity: rig.helperSec, macName: "Test Mac", capabilities: [], pairedDevices: rig.devices,
            approvalHandler: { _ in true }, handshakeTimeout: .seconds(30), loopbackOnly: true, maxPendingConnections: 8,
            maxPendingPerSource: 2)
        let server = try LinkServer(configuration: config)
        let ep = try await server.start()
        let target = LinkEndpoint(host: "127.0.0.1", port: ep.tcpPort ?? 0)
        var silent: [TCPMuxWire] = []
        for _ in 0..<2 {
            let w = TCPMuxWire(endpoint: target.tcp, identity: rig.ipadSec, policy: .pairing)
            try await w.start(timeout: .seconds(5))
            silent.append(w)
        }
        // The same address asks again: refused at once, long before the silent ones time out, although 6 of 8 slots are free.
        let extra = TCPMuxWire(endpoint: target.tcp, identity: rig.ipadSec, policy: .pairing)
        try? await extra.start(timeout: .seconds(5))
        #expect(await within(.seconds(5)) { await extra.waitUntilClosed() }, "a third handshake from one address must be refused")
        for w in silent { #expect(await within(.milliseconds(100)) { await w.waitUntilClosed() } == false, "the earlier ones are still waiting") }
        for w in silent { w.close() }
        extra.close()
        await server.stop()
        await rig.tearDown()
    }

    @Test func clientMachineRejectsUnexpectedHelperMessages() {
        let hello = LinkHello(
            protocolMin: 1, protocolMax: 1, capabilities: [], deviceName: "x",
            sceneLimits: LinkSceneLimits(maxWindows: 1, maxStreams: 1, maxPixelWidth: 1, maxPixelHeight: 1, maxFramesPerSecond: 1))
        var machine = ClientSessionMachine(hello: hello, mode: .pairWithSAS, ownSPKIHash: Data(count: 32), peerSPKIHash: Data(count: 32), exporter: nil)
        _ = machine.start()
        let hostile: [LinkMessage] = [
            .windowDestroyed(1), .pairOK(LinkPairOK(macName: "m", helperID: LinkBytes32(repeating: 1))),
            .sasReveal(LinkBytes32(repeating: 3)), .welcome(LinkWelcome(
                protocolVersion: 1, sessionID: 1, resumeToken: LinkBytes32(repeating: 1), macName: "m", displays: [], capabilities: [])),
        ]
        for bad in hostile {
            var m = machine
            guard case .terminate? = m.receive(bad).first else { Issue.record("expected termination for \(bad.type)"); continue }
        }
    }
}
