import CryptoKit
import Foundation

public typealias LinkClock = @Sendable () -> Date

/// A pairing offer the helper shows as a QR code.
public struct PairingOffer: Sendable, Equatable {
    public let secret: Data
    public let nonce: Data
    public let expiry: Date
}

/// Helper-side state for pairing secrets: single use, 5 minutes, 3 failed attempts per secret.
///
/// A proof names its offer by nonce (`pair.prove` carries the QR nonce), so a wrong proof is charged to that one offer and
/// never to the others. Rate limits are per remote address, so one host on the LAN cannot spend anybody else's budget:
///
/// - a proof for a known offer counts against its source's `maxAttemptsPerHour`;
/// - a proof for an unknown, expired or used nonce is refused cheaply and counts only against its source's
///   `maxUnknownNonceAttemptsPerHour`. It touches no offer and no other source's budget.
public final class PairingSecretLedger: @unchecked Sendable {
    public static let lifetime: TimeInterval = 300
    public static let maxFailedAttempts = 3
    /// Proofs for known offers, per remote address.
    public static let maxAttemptsPerHour = 10
    /// Proofs naming no outstanding offer, per remote address.
    public static let maxUnknownNonceAttemptsPerHour = 5
    public static let maxOutstandingOffers = 4
    /// Remote addresses remembered; the least recently active are forgotten beyond this.
    public static let maxTrackedSources = 256

    /// `sequence` orders offers by issue time even when the clock returns the same instant for several of them.
    private struct Entry { var offer: PairingOffer; var sequence: UInt64; var failures = 0 }
    private struct SourceBudget { var known: [Date] = []; var unknown: [Date] = []; var last = Date.distantPast }

    private let lock = NSLock()
    private let clock: LinkClock
    private var entries: [Data: Entry] = [:]  // keyed by nonce
    private var sources: [String: SourceBudget] = [:]
    private var nextSequence: UInt64 = 0

    public init(clock: @escaping LinkClock = { Date() }) { self.clock = clock }

    /// Creates a fresh secret and nonce. Oldest outstanding offers are dropped beyond the cap.
    public func issue() throws -> PairingOffer {
        let offer = PairingOffer(
            secret: try LinkRandom.bytes(16), nonce: try LinkRandom.bytes(16),
            expiry: clock().addingTimeInterval(Self.lifetime))
        lock.withLock {
            purgeExpired(now: clock())
            while entries.count >= Self.maxOutstandingOffers,
                  let oldest = entries.min(by: { $0.value.sequence < $1.value.sequence })?.key {
                entries.removeValue(forKey: oldest)
            }
            entries[offer.nonce] = Entry(offer: offer, sequence: nextSequence)
            nextSequence += 1
        }
        return offer
    }

    /// Checks one pairing attempt for the offer identified by `nonce`, made from `source` (a normalised remote address).
    /// `check` receives the offer (so the caller can verify the HMAC) and returns whether the proof was valid. A valid proof
    /// burns the secret; the third failure burns it too.
    public func attempt(nonce: Data, source: String, check: (PairingOffer) -> Bool) throws {
        let offer: PairingOffer = try lock.withLock {
            let now = clock()
            purgeExpired(now: now)
            var budget = sources[source] ?? SourceBudget()
            budget.known.removeAll { now.timeIntervalSince($0) >= 3600 }
            budget.unknown.removeAll { now.timeIntervalSince($0) >= 3600 }
            budget.last = now
            defer { store(budget, for: source, now: now) }
            guard let e = entries[nonce] else {
                guard budget.unknown.count < Self.maxUnknownNonceAttemptsPerHour else { throw PairingError.rateLimited }
                budget.unknown.append(now)
                throw PairingError.unknownOrUsedSecret
            }
            guard budget.known.count < Self.maxAttemptsPerHour else { throw PairingError.rateLimited }
            budget.known.append(now)
            return e.offer
        }
        let ok = check(offer)
        try lock.withLock {
            guard var e = entries[nonce] else { throw PairingError.unknownOrUsedSecret }
            if ok {
                entries.removeValue(forKey: nonce)
                return
            }
            e.failures += 1
            if e.failures >= Self.maxFailedAttempts {
                entries.removeValue(forKey: nonce)
                throw PairingError.tooManyAttempts
            }
            entries[nonce] = e
            throw PairingError.invalidProof
        }
    }

    /// Caller holds the lock.
    private func store(_ budget: SourceBudget, for source: String, now: Date) {
        sources[source] = budget
        guard sources.count > Self.maxTrackedSources else { return }
        sources = sources.filter { _, b in
            b.known.contains { now.timeIntervalSince($0) < 3600 } || b.unknown.contains { now.timeIntervalSince($0) < 3600 }
        }
        while sources.count > Self.maxTrackedSources,
              let oldest = sources.min(by: { $0.value.last < $1.value.last })?.key {
            sources.removeValue(forKey: oldest)
        }
    }

    /// Burns every outstanding offer (a pairing succeeded: the QR codes on screen are no longer good).
    public func revokeAll() { lock.withLock { entries.removeAll() } }

    public func revoke(nonce: Data) { _ = lock.withLock { entries.removeValue(forKey: nonce) } }

    private func purgeExpired(now: Date) {
        entries = entries.filter { $0.value.offer.expiry > now }
    }
}

/// Helper-side store of resume tokens: 32 random bytes, 10 minutes, single use, bound to the peer's SPKI hash.
public final class ResumeTokenStore: @unchecked Sendable {
    public static let lifetime: TimeInterval = 600
    public static let maxOutstanding = 64

    private struct Entry { var identity: Data; var expiry: Date; var sequence: UInt64 }

    private let lock = NSLock()
    private let clock: LinkClock
    private var entries: [Data: Entry] = [:]  // keyed by SHA-256(token): the token itself is not retained
    private var nextSequence: UInt64 = 0

    public init(clock: @escaping LinkClock = { Date() }) { self.clock = clock }

    public func issue(for identityHash: Data) throws -> Data {
        guard identityHash.count == 32 else { throw PairingError.invalidInput("identity hash") }
        let token = try LinkRandom.bytes(32)
        lock.withLock {
            let now = clock()
            entries = entries.filter { $0.value.expiry > now }
            while entries.count >= Self.maxOutstanding,
                  let oldest = entries.min(by: { $0.value.sequence < $1.value.sequence })?.key {
                entries.removeValue(forKey: oldest)
            }
            entries[Data(SHA256.hash(data: token))] = Entry(
                identity: identityHash, expiry: now.addingTimeInterval(Self.lifetime), sequence: nextSequence)
            nextSequence += 1
        }
        return token
    }

    /// Forgets every token of one identity (the device was revoked).
    public func invalidate(identityHash: Data) {
        lock.withLock { entries = entries.filter { !constantTimeEqual($0.value.identity, identityHash) } }
    }

    /// Consumes a token. It is burned on any presentation, valid or not, so a stolen token cannot be probed.
    public func consume(_ token: Data, identityHash: Data) -> Bool {
        guard token.count == 32 else { return false }
        return lock.withLock {
            guard let e = entries.removeValue(forKey: Data(SHA256.hash(data: token))) else { return false }
            return e.expiry > clock() && constantTimeEqual(e.identity, identityHash)
        }
    }
}
