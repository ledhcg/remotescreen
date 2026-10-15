import Foundation
import LinkProtocol

/// Framing of the TCP+TLS fallback: several logical streams share one TLS connection.
///
/// Each mux frame is `u8 type | u32 stream id | u16 length | payload`, little-endian, header 7 bytes.
///
/// | type | value | payload | meaning |
/// |---|---|---|---|
/// | open | 1 | stream preamble (1 or 5 bytes, see `LinkStreamKind`) | the sender opens a stream |
/// | data | 2 | 1...16384 bytes | bytes of the stream (the usual `LinkFrameEncoder` framing, split at will) |
/// | fin | 3 | none | the sender will write no more on this stream |
/// | reset | 4 | none | the sender abandons the stream; both directions end |
///
/// Stream ids: the iPad uses odd ids, the Mac even ids, both starting at their lowest value and strictly increasing. Id 0 is
/// invalid. The receiver rejects a wrong parity, a reused or decreasing id, data before `open`, data on a stream the sender
/// finished, an `open` whose kind the sender may not open, and more than `maxOpenStreams` concurrent streams from one side.
/// A payload length above the cap for its type is rejected from the header alone, before any payload byte is buffered.
enum LinkMuxFrameType: UInt8 { case open = 1, data = 2, fin = 3, reset = 4 }

enum LinkMuxError: Error, Equatable {
    case malformed(String)
    case limit(String)
}

enum LinkMux {
    static let headerBytes = 7
    static let maxDataBytes = 16 * 1024
    static let maxOpenStreamsPerSide = 128
    /// Hard stop on how many streams one side may open over the life of a connection.
    static let maxStreamsOpenedTotal: UInt32 = 1 << 20

    static func isClientInitiated(_ id: UInt32) -> Bool { id & 1 == 1 }
}

enum LinkMuxFrame: Equatable {
    case open(streamID: UInt32, kind: LinkStreamKind)
    case data(streamID: UInt32, Data)
    case fin(streamID: UInt32)
    case reset(streamID: UInt32)
}

enum LinkMuxEncoder {
    static func encode(_ frame: LinkMuxFrame) -> Data {
        switch frame {
        case .open(let id, let kind): return make(.open, id, kind.preamble)
        case .data(let id, let d):
            precondition(!d.isEmpty && d.count <= LinkMux.maxDataBytes)
            return make(.data, id, d)
        case .fin(let id): return make(.fin, id, Data())
        case .reset(let id): return make(.reset, id, Data())
        }
    }

    private static func make(_ type: LinkMuxFrameType, _ id: UInt32, _ payload: Data) -> Data {
        var out = Data(capacity: LinkMux.headerBytes + payload.count)
        out.append(type.rawValue)
        withUnsafeBytes(of: id.littleEndian) { out.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt16(payload.count).littleEndian) { out.append(contentsOf: $0) }
        out.append(payload)
        return out
    }
}

/// Incremental decoder. After the first error it stays failed.
struct LinkMuxDecoder {
    private var buffer: [UInt8] = []
    private var head = 0
    private var failure: LinkMuxError?

    mutating func feed(_ data: Data) throws -> [LinkMuxFrame] {
        if let failure { throw failure }
        buffer.append(contentsOf: data)
        var frames: [LinkMuxFrame] = []
        do {
            while buffer.count - head >= LinkMux.headerBytes {
                let h = head
                guard let type = LinkMuxFrameType(rawValue: buffer[h]) else { throw LinkMuxError.malformed("frame type") }
                let id = UInt32(buffer[h + 1]) | UInt32(buffer[h + 2]) << 8 | UInt32(buffer[h + 3]) << 16 | UInt32(buffer[h + 4]) << 24
                let length = Int(buffer[h + 5]) | Int(buffer[h + 6]) << 8
                guard id != 0 else { throw LinkMuxError.malformed("stream id 0") }
                switch type {
                case .open: guard length == 1 || length == LinkStreamKind.maxPreambleBytes else { throw LinkMuxError.malformed("open length") }
                case .data: guard (1...LinkMux.maxDataBytes).contains(length) else { throw LinkMuxError.limit("data length \(length)") }
                case .fin, .reset: guard length == 0 else { throw LinkMuxError.malformed("fin/reset length") }
                }
                guard buffer.count - h >= LinkMux.headerBytes + length else { break }
                let payload = Data(buffer[(h + LinkMux.headerBytes)..<(h + LinkMux.headerBytes + length)])
                head += LinkMux.headerBytes + length
                switch type {
                case .open:
                    guard case .complete(let kind, let used) = LinkStreamKind.parsePreamble(payload), used == payload.count else {
                        throw LinkMuxError.malformed("open preamble")
                    }
                    frames.append(.open(streamID: id, kind: kind))
                case .data: frames.append(.data(streamID: id, payload))
                case .fin: frames.append(.fin(streamID: id))
                case .reset: frames.append(.reset(streamID: id))
                }
            }
        } catch let e as LinkMuxError {
            failure = e
            buffer = []; head = 0
            throw e
        }
        if head == buffer.count { buffer.removeAll(keepingCapacity: true); head = 0 }
        else if head > 64 * 1024 { buffer.removeFirst(head); head = 0 }
        return frames
    }
}

/// Per-connection bookkeeping of the peer's streams: enforces the rules in the type documentation above.
struct LinkMuxStreamTable {
    /// `true` when we are the iPad.
    let weAreClient: Bool
    private var peerHighestID: UInt32 = 0
    private var peerOpened: UInt32 = 0
    private var peerOpen: [UInt32: (kind: LinkStreamKind, finished: Bool)] = [:]
    private var recentlyClosed: [UInt32] = []
    private var ourNextID: UInt32
    private var ourOpened: UInt32 = 0

    init(weAreClient: Bool) {
        self.weAreClient = weAreClient
        ourNextID = weAreClient ? 1 : 2
    }

    var peerOpenCount: Int { peerOpen.count }

    mutating func allocateOurID() throws -> UInt32 {
        guard ourOpened < LinkMux.maxStreamsOpenedTotal else { throw LinkMuxError.limit("streams opened") }
        defer { ourNextID += 2; ourOpened += 1 }
        return ourNextID
    }

    /// Records a peer `open`.
    mutating func peerOpens(id: UInt32, kind: LinkStreamKind) throws {
        guard LinkMux.isClientInitiated(id) == !weAreClient else { throw LinkMuxError.malformed("stream id parity") }
        guard id > peerHighestID else { throw LinkMuxError.malformed("stream id reused or decreasing") }
        // The peer may only open kinds it is allowed to open.
        guard kind.openedByClient == !weAreClient else { throw LinkMuxError.malformed("stream kind not openable by peer") }
        guard peerOpen.count < LinkMux.maxOpenStreamsPerSide else { throw LinkMuxError.limit("concurrent streams") }
        guard peerOpened < LinkMux.maxStreamsOpenedTotal else { throw LinkMuxError.limit("streams opened") }
        peerHighestID = id
        peerOpened += 1
        peerOpen[id] = (kind, false)
    }

    enum DataVerdict: Equatable { case accept(LinkStreamKind), ignore }

    /// Data from the peer for `id`. Unknown ids are an error unless we closed the stream ourselves a moment ago.
    mutating func peerData(id: UInt32) throws -> DataVerdict {
        if let s = peerOpen[id] {
            guard !s.finished else { throw LinkMuxError.malformed("data after fin") }
            return .accept(s.kind)
        }
        if let kind = ourStreamKinds[id] {
            // Peer writes on a stream we opened: only bidirectional streams allow that.
            guard kind.isBidirectional else { throw LinkMuxError.malformed("peer wrote on a one-way stream") }
            return .accept(kind)
        }
        if recentlyClosed.contains(id) { return .ignore }
        throw LinkMuxError.malformed("data for unknown stream")
    }

    mutating func peerFinishes(id: UInt32) throws {
        if var s = peerOpen[id] {
            guard !s.finished else { throw LinkMuxError.malformed("duplicate fin") }
            s.finished = true
            peerOpen[id] = s
            return
        }
        if ourStreamKinds[id] != nil || recentlyClosed.contains(id) { return }
        throw LinkMuxError.malformed("fin for unknown stream")
    }

    mutating func peerResets(id: UInt32) {
        peerOpen.removeValue(forKey: id)
        ourStreamKinds.removeValue(forKey: id)
        noteClosed(id)
    }

    // Streams we opened (kinds), so peer frames for them can be validated.
    private(set) var ourStreamKinds: [UInt32: LinkStreamKind] = [:]

    mutating func weOpened(id: UInt32, kind: LinkStreamKind) { ourStreamKinds[id] = kind }

    /// Forget a stream that ended in both directions or was reset locally.
    mutating func removeStream(id: UInt32) {
        peerOpen.removeValue(forKey: id)
        ourStreamKinds.removeValue(forKey: id)
        noteClosed(id)
    }

    private mutating func noteClosed(_ id: UInt32) {
        recentlyClosed.append(id)
        if recentlyClosed.count > 1024 { recentlyClosed.removeFirst(recentlyClosed.count - 1024) }
    }
}
