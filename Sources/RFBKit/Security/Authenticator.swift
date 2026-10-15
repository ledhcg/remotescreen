import Foundation
import RFBCrypto

public struct RFBCredentials: Sendable, Equatable {
    /// Account name. Used only for Apple Remote Desktop (type 30); VNC Authentication ignores it.
    public var username: String
    public var password: String

    public init(username: String = "", password: String = "") {
        self.username = username
        self.password = password
    }
}

/// Performs the authentication step after the client has chosen a security type.
///
/// Supported: None (1), VNC Authentication (2), Apple Remote Desktop (30).
/// Apple's other types (31 to 36) are not yet understood, see `docs/protocol-notes.md`.
public enum Authenticator {
    /// DH primes smaller than this are rejected, so a server (or man in the middle) cannot force a downgrade to a weak group.
    /// 1024-bit is no longer considered safe enough; macOS uses 4096-bit.
    static let minimumPrimeBits = 2048
    /// Number of Miller-Rabin rounds for unknown groups (maximum error 4^-6). Known groups (`KnownDHGroups`) need no check.
    static let primalityRounds = 6
    /// `p - 1` is divisible by at most 2^32. Real DH primes almost always have `p - 1 = 2q` or `2·odd`; a structure that skewed
    /// is both unusable for DH and forces Miller-Rabin to square a very large number of times.
    static let maximumTwoPowerInPMinusOne = 32
    /// Apple's server uses 4096-bit, i.e. 512 bytes. The 1024-byte cap (8192-bit) rejects absurd parameters.
    static let maximumKeyLength = 1024
    static let ardFieldLength = 64

    public static func authenticate(
        type: RFBSecurityType,
        version: RFBVersion,
        credentials: RFBCredentials,
        over stream: some ByteStream,
        privateExponentBits: Int = 512
    ) async throws {
        switch type {
        case .noAuthentication:
            break
        case .vncAuthentication:
            try await authenticateVNC(password: credentials.password, over: stream)
        case .appleRemoteDesktop:
            try await authenticateARD(
                credentials: credentials, privateExponentBits: privateExponentBits, over: stream
            )
        default:
            throw RFBError.unsupportedSecurityType(type)
        }

        // From 3.8 the server always sends SecurityResult. Before that, type None has no such step.
        if type != .noAuthentication || version >= .v3_8 {
            try await readSecurityResult(version: version, over: stream)
        }
    }

    // MARK: - VNC Authentication (type 2)

    private static func authenticateVNC(password: String, over stream: some ByteStream) async throws {
        let challenge = try await stream.read(exactly: 16)
        try await stream.write(try VNCAuthentication.response(to: challenge, password: password))
    }

    // MARK: - Apple Remote Desktop (type 30)

    /// Flow observed on `screensharingd` (macOS 27), see `docs/protocol-notes.md` section 3:
    ///
    ///     server → client: generator (2) | key length N (2) | prime p (N) | public key B (N)
    ///     client → server: encrypted credentials (128) | public key A (N)
    ///
    /// The AES key = MD5(shared secret) and the 64+64 byte layout of the credentials block were confirmed by a real login to
    /// `screensharingd` (macOS 27) with a 4096-bit group. ARD does not authenticate the server, so the parameter checks here only reject
    /// weak parameters; a full man in the middle can still impersonate the server. Therefore use it only on a trusted network.
    private static func authenticateARD(
        credentials: RFBCredentials,
        privateExponentBits: Int,
        over stream: some ByteStream
    ) async throws {
        let generatorValue = try await stream.readUInt16()
        let keyLength = Int(try await stream.readUInt16())
        guard keyLength * 8 >= minimumPrimeBits, keyLength <= maximumKeyLength else {
            throw RFBError.invalidKeyExchange("key length of \(keyLength) bytes is outside the accepted range")
        }

        let prime = BigUInt(bigEndianBytes: try await stream.read(exactly: keyLength))
        let serverPublic = BigUInt(bigEndianBytes: try await stream.read(exactly: keyLength))

        guard prime.isOdd, prime.bitWidth >= minimumPrimeBits else {
            throw RFBError.invalidKeyExchange("invalid prime p")
        }
        guard try isAcceptableGroup(prime) else {
            throw RFBError.invalidKeyExchange("prime p is not prime, or its structure is unusable for DH")
        }
        guard generatorValue >= 2 else {
            throw RFBError.invalidKeyExchange("invalid generator \(generatorValue)")
        }
        let one = BigUInt(1)
        guard serverPublic > one, serverPublic < prime - one else {
            throw RFBError.invalidKeyExchange("server public key is outside the range (1, p-1)")
        }

        let secret = BigUInt(bigEndianBytes: try SecureRandom.bytes((privateExponentBits + 7) / 8))
        guard secret.bitWidth > 1 else { throw RFBError.invalidKeyExchange("generated private key is too small") }

        let clientPublic = BigUInt(UInt64(generatorValue)).modPow(secret, modulus: prime)
        let shared = serverPublic.modPow(secret, modulus: prime)
        let aesKey = MD5.hash(Data(shared.bigEndianBytes(paddedTo: keyLength)))

        let encrypted = try AES128ECB.encrypt(try credentialBlock(for: credentials), key: aesKey)
        try await stream.write(encrypted + Data(clientPublic.bigEndianBytes(paddedTo: keyLength)))
    }

    /// `p` is a known group, or a (probable) prime with a usable structure. Stops a server from sending a "smooth" composite so that it can compute the
    /// shared secret and then decrypt the credentials block.
    static func isAcceptableGroup(_ prime: BigUInt) throws -> Bool {
        if prime == KnownDHGroups.modp4096 { return true }
        var twoPower = 0
        while !(prime - BigUInt(1)).bit(at: twoPower) { twoPower += 1 }
        guard twoPower <= maximumTwoPowerInPMinusOne else { return false }
        return try prime.isProbablePrime(rounds: primalityRounds)
    }

    /// 128-byte block: name (64) then password (64), each field NUL-terminated, the rest padded with random bytes.
    static func credentialBlock(for credentials: RFBCredentials) throws -> Data {
        var block = try SecureRandom.bytes(2 * ardFieldLength)
        for (offset, name, text) in [(0, "username", credentials.username), (ardFieldLength, "password", credentials.password)] {
            let bytes = Array(text.utf8)
            guard bytes.count < ardFieldLength else { throw RFBError.credentialTooLong(field: name) }
            block.replaceSubrange(offset..<offset + bytes.count, with: bytes)
            block[offset + bytes.count] = 0
        }
        return Data(block)
    }

    // MARK: - SecurityResult

    /// 4 bytes: 0 is success. From 3.8, a failure is followed by a reason string.
    private static func readSecurityResult(version: RFBVersion, over stream: some ByteStream) async throws {
        guard try await stream.readUInt32() != 0 else { return }
        let reason = version >= .v3_8 ? try await Handshake.readReason(from: stream) : "authentication failed"
        throw RFBError.authenticationFailed(reason: reason)
    }
}
