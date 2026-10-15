import Foundation
import Testing
@testable import SessionKit

private final class Clock: @unchecked Sendable {
    var now: TimeInterval = 0
}

private final class Fake {
    let id: Int
    init(_ id: Int) { self.id = id }
}

@Suite("SharedSessionPool")
struct SharedSessionPoolTests {
    private let clock = Clock()
    private func pool() -> SharedSessionPool<String, Fake> {
        let clock = self.clock
        return SharedSessionPool(grace: 30, now: { clock.now })
    }

    @Test func secondAcquireSharesTheSessionAndCountsReferences() {
        var pool = pool()
        var made = 0
        let a = pool.acquire("mac") { made += 1; return Fake(1) }
        let b = pool.acquire("mac") { made += 1; return Fake(2) }
        #expect(a === b)
        #expect(made == 1)
        #expect(pool.referenceCount(for: "mac") == 2)
    }

    @Test func lastReleaseStartsGraceAndExpiryHappensAtTheDeadline() {
        var pool = pool()
        _ = pool.acquire("mac") { Fake(1) }
        clock.now = 10
        pool.release("mac")
        #expect(pool.nextDeadline == 40)
        clock.now = 39.9
        #expect(pool.collectExpired().isEmpty)
        #expect(pool.session(for: "mac") != nil)
        clock.now = 40
        #expect(pool.collectExpired().count == 1)
        #expect(pool.session(for: "mac") == nil)
        #expect(pool.nextDeadline == nil)
    }

    @Test func reacquireDuringGraceKeepsTheSameSessionAndCancelsTheCountdown() {
        var pool = pool()
        let first = pool.acquire("mac") { Fake(1) }
        pool.release("mac")
        clock.now = 20
        let again = pool.acquire("mac") { Fake(2) }
        #expect(first === again)
        #expect(pool.nextDeadline == nil)
        clock.now = 100
        #expect(pool.collectExpired().isEmpty)
    }

    @Test func sessionStaysWhileAnyWindowStillHoldsIt() {
        var pool = pool()
        _ = pool.acquire("mac") { Fake(1) }
        _ = pool.acquire("mac") { Fake(1) }
        pool.release("mac")
        clock.now = 1000
        #expect(pool.collectExpired().isEmpty)
        #expect(pool.referenceCount(for: "mac") == 1)
    }

    @Test func extraAndUnknownReleasesAreIgnored() {
        var pool = pool()
        pool.release("nobody")
        _ = pool.acquire("mac") { Fake(1) }
        pool.release("mac")
        pool.release("mac")
        #expect(pool.referenceCount(for: "mac") == 0)
        #expect(pool.nextDeadline == 30)
    }

    @Test func expiryAfterGraceThenNewAcquireCreatesAFreshSession() {
        var pool = pool()
        let first = pool.acquire("mac") { Fake(1) }
        pool.release("mac")
        clock.now = 31
        _ = pool.collectExpired()
        let second = pool.acquire("mac") { Fake(2) }
        #expect(first !== second)
    }

    @Test func keysAreIndependentAndDrainReturnsEverything() {
        var pool = pool()
        _ = pool.acquire("a") { Fake(1) }
        _ = pool.acquire("b") { Fake(2) }
        pool.release("a")
        clock.now = 31
        #expect(pool.collectExpired().map(\.id) == [1])
        #expect(pool.drain().map(\.id) == [2])
        #expect(pool.count == 0)
    }
}

@Suite("SceneRole")
struct SceneRoleTests {
    @Test func roundTripsThroughJSON() throws {
        let id = UUID()
        for role in [SceneRole.desktop, .launcher(computerID: id), .remoteWindow(computerID: id, windowRef: "w1")] {
            let decoded = try JSONDecoder().decode(SceneRole.self, from: JSONEncoder().encode(role))
            #expect(decoded == role)
        }
    }

    @Test func computerIDIsNilOnlyForTheDesktop() {
        let id = UUID()
        #expect(SceneRole.desktop.computerID == nil)
        #expect(SceneRole.launcher(computerID: id).computerID == id)
        #expect(SceneRole.remoteWindow(computerID: id, windowRef: "w").computerID == id)
    }
}
