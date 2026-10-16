import Foundation
import os

/// Merges messages waiting to be sent: drops **pure mouse moves** that a later move has superseded.
///
/// Only has an effect when the link is congested (many messages piled up before a write); on an uncongested network each
/// `post` is written on its own and nothing is lost. Never drops or reorders: button presses and releases (including wheel notches), keys,
/// update requests, clipboard, Apple's own messages.
public struct OutboundCoalescer: Sendable {
    /// Button state of the last mouse event that passed through (kept across merges).
    public private(set) var lastButtons: UInt8 = 0

    public init() {}

    public mutating func coalesce(_ messages: [ClientMessage]) -> [ClientMessage] {
        var result: [ClientMessage] = []
        result.reserveCapacity(messages.count)
        for (index, message) in messages.enumerated() {
            guard case .pointerEvent(let buttons, _, _) = message else {
                result.append(message)
                continue
            }
            // Pure move: same buttons as the previous mouse event. Drop it if it is immediately followed by another move with the same buttons.
            let isPureMove = buttons == lastButtons
            if isPureMove, index + 1 < messages.count, case .pointerEvent(let nextButtons, _, _) = messages[index + 1],
               nextButtons == buttons {
                continue
            }
            result.append(message)
            lastButtons = buttons
        }
        return result
    }
}

/// Send queue of a session: `post` appends and wakes the writer task; the writer task takes everything waiting, merges it, and writes once.
final class OutboundQueue: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: (messages: [ClientMessage](), closed: false))
    private let signal: AsyncStream<Void>.Continuation
    /// Each element is one "there is work" signal; several appends while the writer task is busy leave only one signal.
    let wakeups: AsyncStream<Void>

    init() {
        (wakeups, signal) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    func append(_ messages: [ClientMessage]) {
        let accepted = state.withLock { state -> Bool in
            guard !state.closed else { return false }
            state.messages += messages
            return true
        }
        if accepted { signal.yield() }
    }

    func takeAll() -> [ClientMessage] {
        state.withLock { state in
            defer { state.messages.removeAll(keepingCapacity: true) }
            return state.messages
        }
    }

    /// Accepts no more messages. What is already queued stays for the writer to take: the wakeup stream delivers its last signal and
    /// then ends, so the writer flushes once and stops.
    func close() {
        state.withLock { $0.closed = true }
        signal.finish()
    }
}
