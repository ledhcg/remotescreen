import CryptoKit
import Foundation

/// Short-authentication-string pairing (no camera): commit-then-reveal X25519, then both users compare six digits.
///
/// Flow per side: `let sas = SASExchange()`; send `sas.commit`; receive peer commit via `receivePeerCommit`; send
/// `sas.reveal`; receive the peer reveal via `receivePeerReveal` (checks it against the commit); then `code(transcript:)`.
public struct SASExchange: Sendable {
    public static let infoPrefix = Data("screon sas v1".utf8)

    private let privateKey: Curve25519.KeyAgreement.PrivateKey
    private var peerCommit: Data?
    private var peerPublicKey: Data?

    public init() { privateKey = Curve25519.KeyAgreement.PrivateKey() }

    public var reveal: Data { privateKey.publicKey.rawRepresentation }
    /// SHA-256 of the raw ephemeral public key.
    public var commit: Data { Self.commit(forPublicKey: reveal) }

    public static func commit(forPublicKey key: Data) -> Data { Data(SHA256.hash(data: key)) }

    /// Checks a reveal against a commit in constant time.
    public static func verifyReveal(_ reveal: Data, against commit: Data) -> Bool {
        reveal.count == 32 && commit.count == 32 && constantTimeEqual(Self.commit(forPublicKey: reveal), commit)
    }

    public mutating func receivePeerCommit(_ commit: Data) throws {
        guard commit.count == 32 else { throw PairingError.sasProtocolViolation("commit size") }
        guard peerCommit == nil else { throw PairingError.sasProtocolViolation("duplicate commit") }
        peerCommit = commit
    }

    public mutating func receivePeerReveal(_ reveal: Data) throws {
        guard let c = peerCommit else { throw PairingError.sasProtocolViolation("reveal before commit") }
        guard peerPublicKey == nil else { throw PairingError.sasProtocolViolation("duplicate reveal") }
        guard Self.verifyReveal(reveal, against: c) else { throw PairingError.sasCommitMismatch }
        peerPublicKey = reveal
    }

    /// The six-digit code. `transcript` must be identical on both sides (e.g. both SPKI hashes in a fixed role order).
    /// Both ephemeral keys are mixed in, sorted, so the order of roles does not matter.
    public func code(transcript: Data) throws -> String {
        guard let peerKey = peerPublicKey else { throw PairingError.sasProtocolViolation("no reveal") }
        let peer: Curve25519.KeyAgreement.PublicKey
        let shared: SharedSecret
        do {
            peer = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerKey)
            shared = try privateKey.sharedSecretFromKeyAgreement(with: peer)
        } catch { throw PairingError.sasProtocolViolation("key agreement") }
        guard shared.withUnsafeBytes({ $0.contains(where: { $0 != 0 }) }) else {
            throw PairingError.sasProtocolViolation("degenerate key")
        }
        let keys = [reveal, peerKey].sorted { $0.lexicographicallyPrecedes($1) }
        let info = Self.infoPrefix + transcript + keys[0] + keys[1]
        let out = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data(), sharedInfo: info, outputByteCount: 4)
        let value = out.withUnsafeBytes { $0.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) } } % 1_000_000
        let s = String(value)
        return String(repeating: "0", count: 6 - s.count) + s
    }
}
