import Foundation

/// A bounded, single-consumer async sequence. Unlike `AsyncStream` it applies back pressure: when the consumer falls behind,
/// `push` suspends, the reader task that feeds it stops reading, and QUIC (or TCP) flow control slows the sender. Nothing is
/// ever dropped silently, and memory stays bounded by `capacity` items / `byteCapacity` bytes (soft by one element).
///
/// `finish()` lets the consumer drain what is buffered, then ends the sequence. One consumer at a time.
public final class LinkInbox<Element: Sendable>: AsyncSequence, @unchecked Sendable {
    public typealias AsyncIterator = Iterator

    private let capacity: Int
    private let byteCapacity: Int
    private let lock = NSLock()
    private var items: [(element: Element, cost: Int)] = []
    private var head = 0
    private var bytes = 0
    private var finished = false
    private var consumer: CheckedContinuation<Element?, Never>?
    private var producers: [UInt64: CheckedContinuation<Void, Never>] = [:]
    private var nextProducer: UInt64 = 0

    public init(capacity: Int = 256, byteCapacity: Int = 32 << 20) {
        self.capacity = capacity
        self.byteCapacity = byteCapacity
    }

    private var hasSpace: Bool { items.count - head < capacity && bytes < byteCapacity }

    /// Appends `element`; suspends while the inbox is over capacity. After `finish` the element is discarded.
    func push(_ element: Element, cost: Int) async {
        let handedOff: CheckedContinuation<Element?, Never>? = lock.withLock {
            guard !finished else { return nil }
            if let c = consumer {
                consumer = nil
                return c
            }
            items.append((element, cost))
            bytes += cost
            return nil
        }
        if let c = handedOff { c.resume(returning: element); return }
        // The element is buffered; a cancelled producer only stops waiting for room (it never blocks a cancelled reader task).
        let id: UInt64 = lock.withLock { defer { nextProducer += 1 }; return nextProducer }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                let resumeNow: Bool = lock.withLock {
                    if finished || hasSpace || Task.isCancelled { return true }
                    producers[id] = cont
                    return false
                }
                if resumeNow { cont.resume() }
            }
        } onCancel: {
            let cont = lock.withLock { producers.removeValue(forKey: id) }
            cont?.resume()
        }
    }

    func finish() {
        let (c, ps): (CheckedContinuation<Element?, Never>?, [CheckedContinuation<Void, Never>]) = lock.withLock {
            finished = true
            let c = consumer, ps = Array(producers.values)
            consumer = nil; producers = [:]
            return (c, ps)
        }
        c?.resume(returning: nil)
        for p in ps { p.resume() }
    }

    /// Drops what is buffered, so a consumer that has not read it yet never sees it, then finishes. Used by the helper when a
    /// session ends (revoke, close): messages a peer queued before that moment must not run afterwards.
    func discardBufferedAndFinish() {
        lock.withLock {
            items.removeAll()
            head = 0
            bytes = 0
        }
        finish()
    }

    /// The next element, or `nil` when the inbox is finished. A cancelled reader gets `nil` at once, so `for await` over an
    /// inbox ends when its task is cancelled; before, it waited for one more message, and forever on a quiet stream.
    fileprivate func next() async -> Element? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Element?, Never>) in
                var result: Element??
                var wake: [CheckedContinuation<Void, Never>] = []
                lock.withLock {
                    if head < items.count {
                        let item = items[head]
                        head += 1
                        bytes -= item.cost
                        if head == items.count { items.removeAll(keepingCapacity: true); head = 0 }
                        else if head > 128 { items.removeFirst(head); head = 0 }
                        result = .some(item.element)
                        if hasSpace { wake = Array(producers.values); producers = [:] }
                    } else if finished || Task.isCancelled {
                        result = .some(nil)
                    } else {
                        consumer = cont
                    }
                }
                for p in wake { p.resume() }
                if let result { cont.resume(returning: result) }
            }
        } onCancel: {
            let cont: CheckedContinuation<Element?, Never>? = lock.withLock { defer { consumer = nil }; return consumer }
            cont?.resume(returning: nil)
        }
    }

    public struct Iterator: AsyncIteratorProtocol {
        fileprivate let inbox: LinkInbox
        public mutating func next() async -> Element? { await inbox.next() }
    }

    public func makeAsyncIterator() -> Iterator { Iterator(inbox: self) }
}
