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
    private var producers: [CheckedContinuation<Void, Never>] = []

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
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let resumeNow: Bool = lock.withLock {
                if finished || hasSpace { return true }
                producers.append(cont)
                return false
            }
            if resumeNow { cont.resume() }
        }
    }

    func finish() {
        let (c, ps): (CheckedContinuation<Element?, Never>?, [CheckedContinuation<Void, Never>]) = lock.withLock {
            finished = true
            let c = consumer, ps = producers
            consumer = nil; producers = []
            return (c, ps)
        }
        c?.resume(returning: nil)
        for p in ps { p.resume() }
    }

    fileprivate func next() async -> Element? {
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
                    if hasSpace { wake = producers; producers = [] }
                } else if finished {
                    result = .some(nil)
                } else {
                    consumer = cont
                }
            }
            for p in wake { p.resume() }
            if let result { cont.resume(returning: result) }
        }
    }

    public struct Iterator: AsyncIteratorProtocol {
        fileprivate let inbox: LinkInbox
        public mutating func next() async -> Element? { await inbox.next() }
    }

    public func makeAsyncIterator() -> Iterator { Iterator(inbox: self) }
}
