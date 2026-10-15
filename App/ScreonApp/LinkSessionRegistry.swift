import Foundation
import Observation
import SessionKit

/// Owns the App Mode link sessions, one per computer, shared by all of its windows. Skeleton: the session itself is built by an
/// injected factory so the link transport can be plugged in later without touching the scenes.
@MainActor
@Observable
final class LinkSessionRegistry {
    @ObservationIgnored private var pool: SharedSessionPool<UUID, any AppModeSession>
    @ObservationIgnored private let makeSession: @MainActor (UUID) -> any AppModeSession
    @ObservationIgnored private let now: @Sendable () -> TimeInterval
    @ObservationIgnored private var expiryTask: Task<Void, Never>?

    /// - Parameter makeSession: builds the session for a computer id. The default is a placeholder that does nothing.
    init(grace: TimeInterval = 30, makeSession: @escaping @MainActor (UUID) -> any AppModeSession = { _ in PlaceholderSession() }) {
        let clock = ContinuousClock()
        let origin = clock.now
        let now: @Sendable () -> TimeInterval = {
            let elapsed = origin.duration(to: clock.now)
            return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        }
        self.now = now
        pool = SharedSessionPool(grace: grace, now: now)
        self.makeSession = makeSession
    }

    /// A window of this computer appeared. Balance every call with `release(computerID:)`.
    func acquire(computerID: UUID) -> any AppModeSession {
        let factory = makeSession
        return pool.acquire(computerID) { factory(computerID) }
    }

    /// A window of this computer went away. The session lives on for the grace period in case another window comes back.
    func release(computerID: UUID) {
        pool.release(computerID)
        scheduleExpiry()
    }

    func referenceCount(computerID: UUID) -> Int { pool.referenceCount(for: computerID) }

    private func scheduleExpiry() {
        expiryTask?.cancel()
        guard let deadline = pool.nextDeadline else { return }
        let wait = max(0, deadline - now())
        expiryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled, let self else { return }
            for session in self.pool.collectExpired() { session.close() }
            self.scheduleExpiry()
        }
    }
}

/// Stands in until the link transport exists.
private final class PlaceholderSession: AppModeSession {
    func close() {}
}
