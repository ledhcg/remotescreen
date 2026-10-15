import Foundation
import LinkProtocol

/// Why a message could not be queued.
public enum LinkQueueError: Error, Equatable, Sendable {
    /// The per-stream queue is full. The caller is sending faster than the link drains, or the peer stopped reading.
    case queueFull
}

/// Bounded outbound queue of one stream. Pure value type; the connection actors own one per stream.
///
/// Three policies:
/// - `fifo`: control stream. Strict order, bounded by message count and bytes; overflow throws `queueFull`.
/// - `inputCoalescing`: input stream. Like `RFBKit.OutboundCoalescer`: a *pure pointer move* (same window, buttons and
///   modifiers as the event before it, so not a press or release) that is still waiting is replaced by the next pure move.
///   Latest wins. Presses, releases, scrolls, gestures, keys and text are never dropped or reordered.
/// - `video`: window streams. When queued bytes exceed the cap, every waiting video frame is dropped, the queue enters
///   "awaiting key frame" and deltas are dropped until a key frame arrives. The outcome reports the drops so the helper can
///   request an immediate key frame. Everything that is not a video frame (config, cursor, surfaces) is kept.
struct LinkOutboundQueue {
    enum Policy: Sendable, Equatable {
        case fifo(maxMessages: Int, maxBytes: Int)
        case inputCoalescing(maxMessages: Int)
        case video(maxBytes: Int)

        /// Limits used by the connection for each stream kind.
        static let control = Policy.fifo(maxMessages: 1024, maxBytes: 48 << 20)
        static let input = Policy.inputCoalescing(maxMessages: 1024)
        static let windowVideo = Policy.video(maxBytes: 4 << 20)
        static let audio = Policy.fifo(maxMessages: 256, maxBytes: 1 << 20)
    }

    struct Outcome: Equatable {
        /// Messages discarded by this call (including the new one when it was dropped).
        var dropped = 0
        /// The queue just fell behind and needs a key frame to resynchronise.
        var needsKeyframe = false
        /// Pure pointer moves merged into a later one.
        var coalesced = 0
    }

    private enum Tag { case plain, pointerMove, videoKey, videoDelta }
    private struct Item { var data: Data; var tag: Tag; var pointer: PointerState? }
    private struct PointerState: Equatable { var window: WindowID; var buttons: LinkMouseButtons; var modifiers: LinkModifiers }

    let policy: Policy
    private var items: [Item] = []
    private var head = 0
    private(set) var byteCount = 0
    private(set) var awaitingKeyframe = false
    private var lastPointer: PointerState?

    init(policy: Policy) { self.policy = policy }

    var count: Int { items.count - head }
    var isEmpty: Bool { count == 0 }

    mutating func enqueue(_ message: LinkMessage, encoded: Data) throws -> Outcome {
        switch policy {
        case .fifo(let maxMessages, let maxBytes):
            guard count < maxMessages, isEmpty || byteCount + encoded.count <= maxBytes else { throw LinkQueueError.queueFull }
            append(Item(data: encoded, tag: .plain))
            return Outcome()

        case .inputCoalescing(let maxMessages):
            var outcome = Outcome()
            var tag = Tag.plain
            var state: PointerState?
            if case .inputPointer(let p) = message {
                let s = PointerState(window: p.window, buttons: p.buttons, modifiers: p.modifiers)
                state = s
                let pureMove = lastPointer == s
                lastPointer = s
                if pureMove {
                    tag = .pointerMove
                    if count > 0, items[items.count - 1].tag == .pointerMove, items[items.count - 1].pointer == s {
                        let old = items.removeLast()
                        byteCount -= old.data.count
                        outcome.coalesced = 1
                    }
                }
            }
            if count >= maxMessages {
                // Make room by dropping the oldest waiting pure move; otherwise refuse.
                if let i = items[head...].firstIndex(where: { $0.tag == .pointerMove }) {
                    byteCount -= items[i].data.count
                    items.remove(at: i)
                    outcome.dropped += 1
                } else {
                    throw LinkQueueError.queueFull
                }
            }
            append(Item(data: encoded, tag: tag, pointer: state))
            return outcome

        case .video(let maxBytes):
            var outcome = Outcome()
            let flags: LinkVideoFrameFlags?
            if case .videoFrame(let f) = message { flags = f.flags } else { flags = nil }
            guard let flags else {
                // Config, cursor, surfaces: kept, but bounded by a hard cap so a stalled peer cannot grow it forever.
                guard byteCount + encoded.count <= maxBytes * 4 else { throw LinkQueueError.queueFull }
                append(Item(data: encoded, tag: .plain))
                return outcome
            }
            let isKey = flags.contains(.key)
            if isKey {
                if byteCount + encoded.count > maxBytes { outcome.dropped += dropVideoFrames() }
                awaitingKeyframe = false
                append(Item(data: encoded, tag: .videoKey))
                return outcome
            }
            if awaitingKeyframe {
                outcome.dropped = 1
                return outcome
            }
            if byteCount + encoded.count > maxBytes {
                outcome.dropped = dropVideoFrames() + 1
                outcome.needsKeyframe = true
                awaitingKeyframe = true
                return outcome
            }
            append(Item(data: encoded, tag: .videoDelta))
            return outcome
        }
    }

    mutating func next() -> Data? {
        guard head < items.count else { return nil }
        let item = items[head]
        head += 1
        byteCount -= item.data.count
        if head == items.count {
            items.removeAll(keepingCapacity: true); head = 0
        } else if head > 256 {
            items.removeFirst(head); head = 0
        }
        return item.data
    }

    private mutating func append(_ item: Item) {
        items.append(item)
        byteCount += item.data.count
    }

    private mutating func dropVideoFrames() -> Int {
        var kept: [Item] = []
        var dropped = 0
        for item in items[head...] {
            if item.tag == .videoKey || item.tag == .videoDelta {
                dropped += 1
                byteCount -= item.data.count
            } else {
                kept.append(item)
            }
        }
        items = kept
        head = 0
        return dropped
    }
}
