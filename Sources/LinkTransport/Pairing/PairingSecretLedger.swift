import CryptoKit
import Foundation

public typealias LinkClock = @Sendable () -> Date

/// A pairing offer the helper shows as a QR code.
public struct PairingOffer: Sendable, Equatable {
    public let secret: Data
    public let nonce: Data
    public let expiry: Date
}

/// Helper-side state for pairing secrets: single use, 5 minutes, 3 failed attempts per secret, and a global
/// limit of 10 attempts per hour.
public final class PairingSecretLedger: @unchecked Sendable {
    public static let lifetime: TimeInterval = 300
    public static let maxFailedAttempts = 3
    public static let maxAttemptsPerHour = 10
    public static let maxOutstandingOffers = 4

    /// `sequence` orders offers by issue time even when the clock returns the same instant for several of them.
    private struct Entry { var offer: PairingOffer; var sequence: UInt64; var failures = 0 }

    private let lock = NSLock()
    private let clock: LinkClock
    private var entries: [Data: Entry] = [:]  // keyed by nonce
    private var attempts: [Date] = []
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

    /// Checks one pairing attempt for the offer identified by `nonce`. `check` receives the offer (so the caller can
    /// verify the HMAC) and returns whether the proof was valid. A valid proof burns the secret; the third failure
    /// burns it too. Every call counts towards the global hourly limit.
    public func attempt(nonce: Data, check: (PairingOffer) -> Bool) throws {
        let (offer): PairingOffer = try lock.withLock {
            let now = clock()
            attempts.removeAll { now.timeIntervalSince($0) >= 3600 }
            guard attempts.count < Self.maxAttemptsPerHour else { throw PairingError.rateLimited }
            attempts.append(now)
            purgeExpired(now: now)
            guard let e = entries[nonce] else { throw PairingError.unknownOrUsedSecret }
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

    /// Like `attempt`, for a proof that does not name its offer (`pair.prove` carries no nonce): `check` is tried against
    /// every outstanding offer. The attempt counts once towards the hourly limit. A match burns that offer. When nothing
    /// matches, every outstanding offer is charged one failure (the offer the client meant is unknown), and offers that reach
    /// the limit are burned.
    public func attemptAny(check: (PairingOffer) -> Bool) throws {
        let offers: [PairingOffer] = try lock.withLock {
            let now = clock()
            attempts.removeAll { now.timeIntervalSince($0) >= 3600 }
            guard attempts.count < Self.maxAttemptsPerHour else { throw PairingError.rateLimited }
            attempts.append(now)
            purgeExpired(now: now)
            guard !entries.isEmpty else { throw PairingError.unknownOrUsedSecret }
            return entries.values.sorted { $0.sequence < $1.sequence }.map(\.offer)
        }
        let matched = offers.first(where: check)
        try lock.withLock {
            if let matched {
                guard entries.removeValue(forKey: matched.nonce) != nil else { throw PairingError.unknownOrUsedSecret }
                return
            }
            var burned = false
            for (nonce, var e) in entries {
                e.failures += 1
                if e.failures >= Self.maxFailedAttempts { entries.removeValue(forKey: nonce); burned = true } else { entries[nonce] = e }
            }
            throw burned ? PairingError.tooManyAttempts : PairingError.invalidProof
        }
    }

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

    /// Consumes a token. It is burned on any presentation, valid or not, so a stolen token cannot be probed.
    public func consume(_ token: Data, identityHash: Data) -> Bool {
        guard token.count == 32 else { return false }
        return lock.withLock {
            guard let e = entries.removeValue(forKey: Data(SHA256.hash(data: token))) else { return false }
            return e.expiry > clock() && constantTimeEqual(e.identity, identityHash)
        }
    }
}
