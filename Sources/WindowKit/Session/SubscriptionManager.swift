import Foundation
import LinkProtocol

/// What the connection must send to bring the helper in line with what the scenes want.
public enum SubscriptionCommand: Sendable, Equatable {
    case subscribe(LinkSubscribe)
    case unsubscribe(WindowID)
}

/// Keeps track of which windows the scenes want to see and which of them the helper is currently streaming.
///
/// There is no `pause` message in the protocol: a scene that goes to the background is **unsubscribed** (the helper stops that
/// capture stream) while its wish is remembered, and subscribed again when it returns. A lost connection forgets what the helper
/// had, and `connectionEstablished()` subscribes everything that should be visible again, so a reconnect restores all windows.
/// Pure state machine: it returns commands, the owner sends them.
public struct SubscriptionManager: Sendable, Equatable {
    private struct Entry: Equatable {
        var wanted: LinkSubscribe
        var paused: Bool
        /// What the helper has now (`nil` when it has nothing for this window).
        var sent: LinkSubscribe?
    }

    private var entries: [WindowID: Entry] = [:]
    private var isConnected = false

    public init() {}

    public var connected: Bool { isConnected }

    /// Windows the helper is streaming (as far as this client knows).
    public var streaming: Set<WindowID> { Set(entries.filter { $0.value.sent != nil }.keys) }

    /// Windows that scenes want, paused or not.
    public var wanted: Set<WindowID> { Set(entries.keys) }

    public func isPaused(_ window: WindowID) -> Bool { entries[window]?.paused ?? false }

    /// A scene wants to see `subscription.window` at this size and rate. Calling again with different parameters updates them;
    /// the same parameters send nothing.
    public mutating func subscribe(_ subscription: LinkSubscribe) -> [SubscriptionCommand] {
        var entry = entries[subscription.window] ?? Entry(wanted: subscription, paused: false, sent: nil)
        entry.wanted = subscription
        entries[subscription.window] = entry
        return sync(subscription.window)
    }

    /// The scene no longer shows this window.
    public mutating func unsubscribe(_ window: WindowID) -> [SubscriptionCommand] {
        guard let entry = entries.removeValue(forKey: window) else { return [] }
        return entry.sent != nil && isConnected ? [.unsubscribe(window)] : []
    }

    /// The scene went to the background: stop the stream but remember the wish.
    public mutating func pause(_ window: WindowID) -> [SubscriptionCommand] {
        guard var entry = entries[window], !entry.paused else { return [] }
        entry.paused = true
        entries[window] = entry
        return sync(window)
    }

    /// The scene is active again.
    public mutating func resume(_ window: WindowID) -> [SubscriptionCommand] {
        guard var entry = entries[window], entry.paused else { return [] }
        entry.paused = false
        entries[window] = entry
        return sync(window)
    }

    /// The helper reported that the window is gone: nothing to unsubscribe, the wish is void.
    public mutating func windowDestroyed(_ window: WindowID) { entries[window] = nil }

    /// The control connection is up (also after a reconnect). Subscribes every visible window again.
    public mutating func connectionEstablished() -> [SubscriptionCommand] {
        isConnected = true
        for id in entries.keys { entries[id]?.sent = nil }
        return entries.keys.sorted().flatMap { sync($0) }
    }

    /// The connection ended. The helper dropped its subscriptions with it.
    public mutating func connectionLost() {
        isConnected = false
        for id in entries.keys { entries[id]?.sent = nil }
    }

    public mutating func reset() {
        entries.removeAll()
        isConnected = false
    }

    private mutating func sync(_ window: WindowID) -> [SubscriptionCommand] {
        guard isConnected, var entry = entries[window] else { return [] }
        defer { entries[window] = entry }
        if entry.paused {
            guard entry.sent != nil else { return [] }
            entry.sent = nil
            return [.unsubscribe(window)]
        }
        guard entry.sent != entry.wanted else { return [] }
        entry.sent = entry.wanted
        return [.subscribe(entry.wanted)]
    }
}
