import Foundation

/// Reference-counted sessions shared by several windows, kept alive for a grace period after the last user lets go.
///
/// App Mode can show many windows of one Mac; they must share one link session, and a window that closes and reopens
/// within the grace period (for example while switching apps) must not pay for a new connection.
/// Pure logic: the clock is injected and nothing here sleeps. The owner asks `nextDeadline` when to call `collectExpired`.
public struct SharedSessionPool<Key: Hashable, Session> {
    private struct Entry {
        var session: Session
        var references: Int
        /// Set while `references == 0`: the moment the session may be dropped.
        var deadline: TimeInterval?
    }

    public let grace: TimeInterval
    private let now: () -> TimeInterval
    private var entries: [Key: Entry] = [:]

    /// - Parameters:
    ///   - grace: how long an unreferenced session lives before `collectExpired` returns it.
    ///   - now: a monotonic clock in seconds.
    public init(grace: TimeInterval = 30, now: @escaping () -> TimeInterval) {
        self.grace = grace
        self.now = now
    }

    /// Takes a reference, creating the session with `make` if there is none. Cancels a pending grace countdown.
    public mutating func acquire(_ key: Key, make: () -> Session) -> Session {
        if var entry = entries[key] {
            entry.references += 1
            entry.deadline = nil
            entries[key] = entry
            return entry.session
        }
        let session = make()
        entries[key] = Entry(session: session, references: 1, deadline: nil)
        return session
    }

    /// Gives a reference back. At zero the session stays for `grace` seconds. Unknown keys and extra releases are ignored.
    public mutating func release(_ key: Key) {
        guard var entry = entries[key], entry.references > 0 else { return }
        entry.references -= 1
        if entry.references == 0 { entry.deadline = now() + grace }
        entries[key] = entry
    }

    /// Removes and returns the sessions whose grace period has ended, so the owner can close them.
    public mutating func collectExpired() -> [Session] {
        let current = now()
        var expired: [Session] = []
        for (key, entry) in entries {
            if let deadline = entry.deadline, deadline <= current {
                expired.append(entry.session)
                entries[key] = nil
            }
        }
        return expired
    }

    /// Removes everything at once (app shutting down), regardless of references.
    public mutating func drain() -> [Session] {
        defer { entries.removeAll() }
        return entries.values.map(\.session)
    }

    public func session(for key: Key) -> Session? { entries[key]?.session }
    public func referenceCount(for key: Key) -> Int { entries[key]?.references ?? 0 }
    public var count: Int { entries.count }

    /// The earliest moment `collectExpired` will return something, or `nil` if no countdown is running.
    public var nextDeadline: TimeInterval? { entries.values.compactMap(\.deadline).min() }
}
