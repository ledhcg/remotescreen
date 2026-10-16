import Foundation
import LinkProtocol
import Network
import Testing
@testable import LinkTransport

@Suite struct LinkInboxTests {
    @Test func deliversInOrderAndDrainsAfterFinish() async {
        let inbox = LinkInbox<Int>(capacity: 8)
        for i in 0..<5 { await inbox.push(i, cost: 1) }
        inbox.finish()
        var got: [Int] = []
        for await v in inbox { got.append(v) }
        #expect(got == [0, 1, 2, 3, 4], "finish lets the consumer drain what is buffered")
        await inbox.push(99, cost: 1)  // after finish: discarded, never blocks
    }

    @Test func producerWaitsWhenTheConsumerIsBehind() async {
        let inbox = LinkInbox<Int>(capacity: 2, byteCapacity: 1 << 20)
        let pushed = Counter()
        let producer = Task {
            for i in 0..<10 {
                await inbox.push(i, cost: 1)
                await pushed.increment()
            }
        }
        // With nobody reading, the producer stalls shortly after the capacity (soft by one element).
        _ = await within(.milliseconds(300)) { while await pushed.value < 10 { await Task.yield() } }
        #expect(await pushed.value <= 4, "bounded: the producer is held back")
        var it = inbox.makeAsyncIterator()
        var got: [Int] = []
        while got.count < 10, let v = await it.next() { got.append(v) }
        #expect(got == Array(0..<10))
        await producer.value
    }

    @Test func byteCapacityAlsoBounds() async {
        let inbox = LinkInbox<Int>(capacity: 1000, byteCapacity: 100)
        let pushed = Counter()
        let producer = Task {
            for i in 0..<10 {
                await inbox.push(i, cost: 60)
                await pushed.increment()
            }
        }
        _ = await within(.milliseconds(300)) { while await pushed.value < 10 { await Task.yield() } }
        #expect(await pushed.value <= 3)
        inbox.finish()
        await producer.value
    }

    @Test func discardDropsBufferedItemsAndReleasesBlockedProducers() async {
        let inbox = LinkInbox<Int>(capacity: 2, byteCapacity: 1 << 20)
        let producer = Task { for i in 0..<50 { await inbox.push(i, cost: 1) } }
        try? await Task.sleep(for: .milliseconds(50))
        inbox.discardBufferedAndFinish()
        #expect(await within(.seconds(2)) { await producer.value }, "a producer blocked on capacity is released")
        var got = 0
        for await _ in inbox { got += 1 }
        #expect(got == 0, "nothing buffered survives the discard, nothing is accepted afterwards")
    }

    @Test func concurrentPushFinishAndConsumeNeverHangsOrDuplicates() async {
        for _ in 0..<200 {
            let inbox = LinkInbox<Int>(capacity: 4)
            let producer = Task { for i in 0..<20 { await inbox.push(i, cost: 1) } }
            let consumer = Task { () -> [Int] in var r: [Int] = []; for await v in inbox { r.append(v) }; return r }
            await Task.yield()
            inbox.finish()
            await producer.value
            let got = await consumer.value
            #expect(got == Array(0..<got.count), "in order, no duplicates, no gaps")
        }
    }

    @Test func finishWakesAWaitingConsumer() async {
        let inbox = LinkInbox<Int>()
        let consumer = Task { () -> Int? in var it = inbox.makeAsyncIterator(); return await it.next() }
        try? await Task.sleep(for: .milliseconds(20))
        inbox.finish()
        #expect(await consumer.value == nil)
    }
}

actor Counter {
    private(set) var value = 0
    func increment() { value += 1 }
}

@Suite struct BonjourTests {
    @Test func txtRecordCarriesVersionAndShortFingerprint() throws {
        let hash = Data((0..<32).map { UInt8($0) })
        #expect(LinkBonjour.fingerprint(spkiHash: hash) == "00010203")
        let txt = LinkBonjour.txtRecord(spkiHash: hash)
        #expect(txt["v"] == "1" && txt["fp"] == "00010203")
        #expect(LinkBonjour.parse(txt) == LinkBonjour.Advertisement(version: "1", fingerprint: "00010203"))
        #expect(LinkTransportInfo.bonjourServiceType == "_screon-link._udp")
    }

    @Test func parsingTreatsTheRecordAsUntrusted() {
        var bad = NWTXTRecord()
        bad["v"] = "2"
        #expect(LinkBonjour.parse(bad) == nil, "unknown version")
        var noVersion = NWTXTRecord()
        noVersion["fp"] = "00010203"
        #expect(LinkBonjour.parse(noVersion) == nil)
        var weirdFingerprint = NWTXTRecord()
        weirdFingerprint["v"] = "1"
        weirdFingerprint["fp"] = "ZZ\u{0}\u{1}"
        #expect(LinkBonjour.parse(weirdFingerprint) == LinkBonjour.Advertisement(version: "1", fingerprint: nil), "bad fingerprint is dropped")
        var huge = NWTXTRecord()
        huge["v"] = "1"
        huge["fp"] = String(repeating: "a", count: 5000)
        #expect(LinkBonjour.parse(huge)?.fingerprint == nil)
    }
}

@Suite(.timeLimit(.minutes(1))) struct BackpressureTests {
    @Test(arguments: [LinkTransportKind.quic, .tcp])
    func stalledReceiverMakesTheVideoQueueDropToAKeyframe(transport: LinkTransportKind) async throws {
        let rig = try LoopbackRig.make()
        let (server, ep) = try await rig.makeServer()
        let payload = try await server.makePairingQRPayload(hostHints: ["127.0.0.1"])
        let client = try await LinkConnection.connect(
            to: rig.endpoint(ep, transport: transport),
            configuration: rig.clientConfiguration(mode: .pairWithQR(payload), transport: transport.preference))
        var sessions = server.connections.makeAsyncIterator()
        let helper = try #require(await sessions.next())
        let helperEvents = EventLog(helper.events)
        let clientEvents = EventLog(client.events)

        func frame(_ seq: UInt32, key: Bool) -> LinkMessage {
            .videoFrame(LinkVideoFrame(
                window: 1, sequence: seq, ptsMicros: UInt64(seq), flags: key ? [.key] : [], data: Data(repeating: UInt8(seq & 0xFF), count: 1 << 20)))
        }
        // The iPad is not reading window 1 at all. The Mac keeps encoding.
        try await helper.send(frame(0, key: true))
        var sent: UInt32 = 1
        func sawPressure() async -> Bool {
            await helperEvents.events.contains { if case .videoBackpressure = $0 { true } else { false } }
        }
        while sent < 600 {
            try await helper.send(frame(sent, key: false))
            sent += 1
            if sent % 4 == 0 {
                await Task.yield()
                if await sawPressure() { break }
            }
        }
        let events = await helperEvents.events
        let pressure = events.compactMap { e -> (Int, Bool)? in
            if case .videoBackpressure(1, let dropped, let needs) = e { (dropped, needs) } else { nil }
        }
        guard !pressure.isEmpty else { Issue.record("\(transport): the queue never reported back pressure after \(sent) frames"); return }
        #expect(pressure.contains { $0.1 }, "the first overflow asks for a key frame")
        #expect(pressure.allSatisfy { $0.0 > 0 })

        // The iPad starts reading. Whatever arrives is in order; the Mac then recovers with a key frame.
        let opened = await clientEvents.wait { if case .streamOpened(.window(1), _) = $0 { true } else { false } }
        guard case .streamOpened(_, let inbox)? = opened else { Issue.record("no stream"); return }
        try await helper.send(frame(100_000, key: true))
        var last: UInt32?
        var sawRecoveryKey = false
        var received = 0
        while let m = await nextElement(inbox, timeout: .seconds(10)) {
            guard case .videoFrame(let f) = m else { continue }
            received += 1
            if let l = last { #expect(f.sequence > l, "frames are never reordered") }
            last = f.sequence
            if f.sequence == 100_000 { sawRecoveryKey = f.flags.contains(.key); break }
        }
        #expect(sawRecoveryKey, "decoding can restart at the recovery key frame")
        #expect(received < Int(sent) + 1, "some frames were dropped, none duplicated")
        await client.close()
        await rig.tearDown()
    }
}
