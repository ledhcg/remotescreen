import Foundation
import LinkProtocol
import Testing
@testable import LinkTransport

@Suite struct StreamPreambleTests {
    @Test func roundTrip() {
        for kind in [LinkStreamKind.control, .input, .audio, .window(WindowID(rawValue: 0xDEAD_BEEF))] {
            let bytes = kind.preamble
            #expect(LinkStreamKind.parsePreamble(bytes) == .complete(kind, consumed: bytes.count))
            #expect(bytes.count <= LinkStreamKind.maxPreambleBytes)
        }
    }

    @Test func incrementalAndInvalid() {
        #expect(LinkStreamKind.parsePreamble([UInt8]()) == .needMore)
        #expect(LinkStreamKind.parsePreamble([3, 1, 2]) == .needMore)
        #expect(LinkStreamKind.parsePreamble([0]) == .invalid)
        #expect(LinkStreamKind.parsePreamble([9, 1, 2, 3, 4]) == .invalid)
        // Bytes after the preamble are not consumed.
        #expect(LinkStreamKind.parsePreamble([1, 0xFF, 0xFF]) == .complete(.control, consumed: 1))
    }
}

@Suite struct MuxFramingTests {
    @Test func roundTripAndByteAtATime() throws {
        let frames: [LinkMuxFrame] = [
            .open(streamID: 1, kind: .control), .open(streamID: 2, kind: .window(7)),
            .data(streamID: 1, Data(repeating: 9, count: 16384)), .fin(streamID: 2), .reset(streamID: 3),
        ]
        let wire = frames.reduce(Data()) { $0 + LinkMuxEncoder.encode($1) }
        var whole = LinkMuxDecoder()
        #expect(try whole.feed(wire) == frames)
        var slow = LinkMuxDecoder()
        var out: [LinkMuxFrame] = []
        for b in wire { out += try slow.feed(Data([b])) }
        #expect(out == frames)
    }

    private func header(type: UInt8, id: UInt32, length: UInt16) -> Data {
        var d = Data([type])
        withUnsafeBytes(of: id.littleEndian) { d.append(contentsOf: $0) }
        withUnsafeBytes(of: length.littleEndian) { d.append(contentsOf: $0) }
        return d
    }

    @Test func rejectsBadHeadersFromTheHeaderAlone() {
        // Each of these must fail with only the 7 header bytes present: nothing is buffered waiting for a hostile length.
        let bad: [Data] = [
            header(type: 0, id: 1, length: 0),  // unknown type
            header(type: 9, id: 1, length: 0),
            header(type: 2, id: 0, length: 1),  // stream id 0
            header(type: 2, id: 1, length: 0),  // empty data
            header(type: 2, id: 1, length: 16385),  // oversized data
            header(type: 2, id: 1, length: 65535),
            header(type: 1, id: 1, length: 2),  // open must be 1 or 5
            header(type: 1, id: 1, length: 6),
            header(type: 3, id: 1, length: 1),  // fin with payload
            header(type: 4, id: 1, length: 1),
        ]
        for h in bad {
            var d = LinkMuxDecoder()
            #expect(throws: LinkMuxError.self) { try d.feed(h) }
            // And it stays failed.
            #expect(throws: LinkMuxError.self) { try d.feed(Data()) }
        }
    }

    @Test func rejectsBadOpenPreamble() {
        var d = LinkMuxDecoder()
        #expect(throws: LinkMuxError.self) { try d.feed(header(type: 1, id: 1, length: 1) + Data([7])) }
        var d2 = LinkMuxDecoder()
        // Window kind needs 5 bytes; one byte of kind 3 is incomplete, not valid.
        #expect(throws: LinkMuxError.self) { try d2.feed(header(type: 1, id: 1, length: 1) + Data([3])) }
    }

    @Test func streamTableRulesOnHelper() throws {
        var t = LinkMuxStreamTable(weAreClient: false)
        try t.peerOpens(id: 1, kind: .control)
        // reuse / decreasing
        #expect(throws: LinkMuxError.self) { try t.peerOpens(id: 1, kind: .input) }
        try t.peerOpens(id: 5, kind: .input)
        #expect(throws: LinkMuxError.self) { try t.peerOpens(id: 3, kind: .audio) }
        // wrong parity (helper ids are even)
        #expect(throws: LinkMuxError.self) { try t.peerOpens(id: 8, kind: .control) }
        // client may not open a window stream
        #expect(throws: LinkMuxError.self) { try t.peerOpens(id: 9, kind: .window(1)) }
        // data on an unknown stream
        #expect(throws: LinkMuxError.self) { _ = try t.peerData(id: 99) }
        // data on a known stream, then fin, then more data
        #expect(try t.peerData(id: 1) == .accept(.control))
        try t.peerFinishes(id: 1)
        #expect(throws: LinkMuxError.self) { _ = try t.peerData(id: 1) }
        #expect(throws: LinkMuxError.self) { try t.peerFinishes(id: 1) }
    }

    @Test func peerCannotWriteOnOneWayStreamWeOpened() throws {
        var t = LinkMuxStreamTable(weAreClient: false)
        let id = try t.allocateOurID()
        #expect(id == 2)
        t.weOpened(id: id, kind: .window(1))
        #expect(throws: LinkMuxError.self) { _ = try t.peerData(id: id) }
        let c = try t.allocateOurID()
        #expect(c == 4)
    }

    @Test func locallyClosedStreamsTolerateLateFrames() throws {
        var t = LinkMuxStreamTable(weAreClient: false)
        try t.peerOpens(id: 1, kind: .control)
        t.removeStream(id: 1)
        #expect(try t.peerData(id: 1) == .ignore)
    }

    @Test func concurrentStreamCapIsEnforced() throws {
        var t = LinkMuxStreamTable(weAreClient: false)
        var id: UInt32 = 1
        for _ in 0..<LinkMux.maxOpenStreamsPerSide {
            try t.peerOpens(id: id, kind: .control)
            id += 2
        }
        #expect(throws: LinkMuxError.self) { try t.peerOpens(id: id, kind: .control) }
    }
}

@Suite struct MessageRulesTests {
    let pointer = LinkMessage.inputPointer(LinkPointerEvent(
        window: 1, point: LinkPoint(x: 1, y: 2), buttons: [], modifiers: []))
    let frame = LinkMessage.videoFrame(LinkVideoFrame(window: 5, sequence: 1, ptsMicros: 0, flags: [.key], data: Data([1])))

    @Test func streamRouting() {
        #expect(LinkMessageRules.streamKind(for: pointer) == .input)
        #expect(LinkMessageRules.streamKind(for: frame) == .window(5))
        #expect(LinkMessageRules.streamKind(for: .ping(timestampMicros: 1)) == .control)
        #expect(LinkMessageRules.streamKind(for: .windowSubscribe(LinkSubscribe(
            window: 1, pixelWidth: 1, pixelHeight: 1, maxFramesPerSecond: 60, quality: .balanced))) == .control)
    }

    @Test func directionAndStreamAreEnforced() {
        // helper side receiving from the client
        #expect(LinkMessageRules.isAllowed(pointer, on: .input, peerIsClient: true))
        #expect(!LinkMessageRules.isAllowed(pointer, on: .control, peerIsClient: true))
        #expect(!LinkMessageRules.isAllowed(frame, on: .window(5), peerIsClient: true), "video flows helper to client only")
        #expect(!LinkMessageRules.isAllowed(.welcome(sampleWelcome()), on: .control, peerIsClient: true))
        #expect(LinkMessageRules.isAllowed(.ping(timestampMicros: 1), on: .control, peerIsClient: true))
        // client side receiving from the helper
        #expect(LinkMessageRules.isAllowed(frame, on: .window(5), peerIsClient: false))
        #expect(!LinkMessageRules.isAllowed(frame, on: .window(6), peerIsClient: false), "frame names another window")
        #expect(!LinkMessageRules.isAllowed(frame, on: .control, peerIsClient: false))
        #expect(!LinkMessageRules.isAllowed(pointer, on: .input, peerIsClient: false))
    }

    func sampleWelcome() -> LinkWelcome {
        LinkWelcome(
            protocolVersion: 1, sessionID: 1, resumeToken: LinkBytes32(repeating: 1), macName: "m", displays: [], capabilities: [])
    }

    @Test func everyMessageTypeHasADirection() {
        for t in LinkMessageType.allCases { _ = LinkMessageRules.direction(of: t) }
    }
}

@Suite struct OutboundQueueTests {
    func pointer(x: Double, buttons: LinkMouseButtons = [], window: WindowID = 1) -> LinkMessage {
        .inputPointer(LinkPointerEvent(window: window, point: LinkPoint(x: x, y: 0), buttons: buttons, modifiers: []))
    }

    func enqueue(_ q: inout LinkOutboundQueue, _ m: LinkMessage) throws -> LinkOutboundQueue.Outcome {
        try q.enqueue(m, encoded: try LinkFrameEncoder.encode(m))
    }

    func drain(_ q: inout LinkOutboundQueue) throws -> [LinkMessage] {
        var out: [LinkMessage] = []
        var dec = LinkFrameDecoder()
        while let d = q.next() { out += try dec.feed(d) }
        return out
    }

    @Test func pureMovesCoalesceLatestWins() throws {
        var q = LinkOutboundQueue(policy: LinkOutboundQueue.Policy.input)
        var coalesced = 0
        for x in 0..<100 { coalesced += try enqueue(&q, pointer(x: Double(x))).coalesced }
        let out = try drain(&q)
        // The first event is an edge-less first move; everything after merges into one.
        #expect(out.count <= 2)
        #expect(coalesced >= 98)
        guard case .inputPointer(let last) = out.last else { Issue.record("no pointer"); return }
        #expect(last.point.x == 99)
    }

    @Test func pressAndReleaseAreNeverDropped() throws {
        var q = LinkOutboundQueue(policy: LinkOutboundQueue.Policy.input)
        _ = try enqueue(&q, pointer(x: 1))
        _ = try enqueue(&q, pointer(x: 2))
        _ = try enqueue(&q, pointer(x: 3, buttons: .left))  // press
        _ = try enqueue(&q, pointer(x: 4, buttons: .left))  // drag
        _ = try enqueue(&q, pointer(x: 5, buttons: .left))  // drag (replaces the previous drag)
        _ = try enqueue(&q, pointer(x: 6, buttons: []))  // release
        _ = try enqueue(&q, pointer(x: 7, buttons: []))
        let out = try drain(&q)
        let summary = out.compactMap { m -> String? in
            if case .inputPointer(let p) = m { return "\(Int(p.point.x)):\(p.buttons.rawValue)" } else { return nil }
        }
        #expect(summary == ["1:0", "2:0", "3:1", "5:1", "6:0", "7:0"], "only a move that follows another move is replaced")
        #expect(summary.contains("3:1"), "the press edge survives")
        #expect(summary.contains("6:0"), "the release edge survives")
        #expect(summary.last == "7:0")
    }

    @Test func keysAndScrollsKeepOrderAndSeparateMoves() throws {
        var q = LinkOutboundQueue(policy: LinkOutboundQueue.Policy.input)
        _ = try enqueue(&q, pointer(x: 1))
        _ = try enqueue(&q, .inputText("a"))
        _ = try enqueue(&q, pointer(x: 2))
        _ = try enqueue(&q, pointer(x: 3))
        let out = try drain(&q)
        #expect(out.count == 3, "text between two moves prevents merging across it; the two later moves merge")
        if case .inputText("a") = out[1] {} else { Issue.record("order changed") }
    }

    @Test func movesInDifferentWindowsDoNotMerge() throws {
        var q2 = LinkOutboundQueue(policy: LinkOutboundQueue.Policy.input)
        _ = try enqueue(&q2, pointer(x: 1, window: 1))
        _ = try enqueue(&q2, pointer(x: 2, window: 2))
        #expect(try drain(&q2).count == 2)
    }

    @Test func inputQueueIsBounded() throws {
        var q = LinkOutboundQueue(policy: .inputCoalescing(maxMessages: 4))
        for i in 0..<4 { _ = try enqueue(&q, .inputText("t\(i)")) }
        #expect(throws: LinkQueueError.self) { try enqueue(&q, .inputText("overflow")) }
        #expect(q.count == 4)
    }

    @Test func fifoOverflowThrows() throws {
        var q = LinkOutboundQueue(policy: .fifo(maxMessages: 3, maxBytes: 1 << 20))
        for _ in 0..<3 { _ = try enqueue(&q, .ping(timestampMicros: 1)) }
        #expect(throws: LinkQueueError.self) { try enqueue(&q, .ping(timestampMicros: 2)) }
        var big = LinkOutboundQueue(policy: .fifo(maxMessages: 100, maxBytes: 100))
        _ = try enqueue(&big, .clipboardData(type: "public.utf8-plain-text", data: Data(repeating: 1, count: 500)))  // empty queue accepts one
        #expect(throws: LinkQueueError.self) { try enqueue(&big, .ping(timestampMicros: 1)) }
    }

    func videoFrame(_ seq: UInt32, key: Bool, bytes: Int, window: WindowID = 1) -> LinkMessage {
        .videoFrame(LinkVideoFrame(window: window, sequence: seq, ptsMicros: UInt64(seq), flags: key ? [.key] : [], data: Data(repeating: 1, count: bytes)))
    }

    @Test func videoDropsToNextKeyframeWhenOverCap() throws {
        var q = LinkOutboundQueue(policy: .video(maxBytes: 10_000))
        _ = try enqueue(&q, .videoConfig(LinkVideoConfig(
            window: 1, codec: .hevc, parameterSets: [Data([1])], pixelWidth: 10, pixelHeight: 10,
            contentRect: LinkRect(x: 0, y: 0, width: 10, height: 10), scale: 2)))
        _ = try enqueue(&q, videoFrame(0, key: true, bytes: 4000))
        _ = try enqueue(&q, videoFrame(1, key: false, bytes: 4000))
        // Third frame does not fit: everything queued is dropped, the queue wants a key frame.
        let o = try enqueue(&q, videoFrame(2, key: false, bytes: 4000))
        #expect(o.needsKeyframe)
        #expect(o.dropped == 3, "two queued frames and the new one")
        #expect(q.awaitingKeyframe)
        // Deltas are dropped until a key frame.
        let o2 = try enqueue(&q, videoFrame(3, key: false, bytes: 100))
        #expect(o2.dropped == 1 && !o2.needsKeyframe)
        let o3 = try enqueue(&q, videoFrame(4, key: true, bytes: 100))
        #expect(o3.dropped == 0 && !q.awaitingKeyframe)
        _ = try enqueue(&q, videoFrame(5, key: false, bytes: 100))
        let out = try drain(&q)
        let kinds = out.map { m -> String in
            switch m {
            case .videoConfig: "config"
            case .videoFrame(let f): "f\(f.sequence)"
            default: "?"
            }
        }
        #expect(kinds == ["config", "f4", "f5"], "config is kept, the stale frames are gone, decoding restarts at the key frame")
    }

    @Test func keyframeThatDoesNotFitReplacesStaleFrames() throws {
        var q = LinkOutboundQueue(policy: .video(maxBytes: 10_000))
        _ = try enqueue(&q, videoFrame(0, key: false, bytes: 6000))
        let o = try enqueue(&q, videoFrame(1, key: true, bytes: 6000))
        #expect(o.dropped == 1 && !o.needsKeyframe)
        #expect(try drain(&q).count == 1)
    }

    @Test func nonVideoMessagesOnAVideoQueueAreBounded() throws {
        var q = LinkOutboundQueue(policy: .video(maxBytes: 1000))
        let shape = LinkMessage.cursorShape(LinkCursorShape(window: 1, id: 1, hotspot: LinkPoint(x: 0, y: 0), png: Data(repeating: 1, count: 900)))
        _ = try enqueue(&q, shape)
        _ = try enqueue(&q, shape)
        _ = try enqueue(&q, shape)
        _ = try enqueue(&q, shape)
        #expect(throws: LinkQueueError.self) { try enqueue(&q, shape) }
    }
}
