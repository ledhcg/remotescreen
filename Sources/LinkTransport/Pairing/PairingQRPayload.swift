import Foundation

public enum PairingError: Error, Equatable {
    case malformedPayload(String)
    case expired
    case invalidProof
    case unknownOrUsedSecret
    case tooManyAttempts
    case rateLimited
    case sasCommitMismatch
    case sasProtocolViolation(String)
    case invalidInput(String)
}

/// Unpadded base64url (RFC 4648 §5). Decoding is strict: alphabet only, no padding, canonical trailing bits.
enum Base64URL {
    static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decode(_ s: String, expectedCount: Int) -> Data? {
        // Exact encoded length for the expected byte count, so nothing oversized is ever decoded.
        let expectedChars = (expectedCount * 4 + 2) / 3
        guard s.utf8.count == expectedChars,
              s.utf8.allSatisfy({ ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x61 && $0 <= 0x7A) || ($0 >= 0x30 && $0 <= 0x39) || $0 == 0x2D || $0 == 0x5F })
        else { return nil }
        var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b += "=" }
        guard let d = Data(base64Encoded: b), d.count == expectedCount, encode(d) == s else { return nil }
        return d
    }
}

/// The content of the pairing QR code (plan §6.2 step 1). Parsing is strict and bounded.
public struct PairingQRPayload: Sendable, Equatable {
    public static let scheme = "screon-pair:v1"
    public static let maxHostHints = 4
    public static let maxHostHintLength = 253
    public static let maxEncodedLength = 1536
    /// Reject expiries further out than this, so a bad clock or hostile QR cannot make a secret long-lived.
    public static let maxLifetime: TimeInterval = 3600

    public var hostHints: [String]
    public var port: UInt16
    /// SHA-256 of the Mac's SubjectPublicKeyInfo.
    public var macSPKIHash: Data
    public var secret: Data
    public var nonce: Data
    public var expiry: Date

    public init(hostHints: [String], port: UInt16, macSPKIHash: Data, secret: Data, nonce: Data, expiry: Date) {
        self.hostHints = hostHints
        self.port = port
        self.macSPKIHash = macSPKIHash
        self.secret = secret
        self.nonce = nonce
        self.expiry = expiry
    }

    public func encoded() throws -> String {
        guard macSPKIHash.count == 32, secret.count == 16, nonce.count == 16 else {
            throw PairingError.invalidInput("field sizes")
        }
        try Self.validate(hostHints: hostHints)
        return "\(Self.scheme);h=\(hostHints.joined(separator: ","));p=\(port);k=\(Base64URL.encode(macSPKIHash));"
            + "s=\(Base64URL.encode(secret));n=\(Base64URL.encode(nonce));e=\(Int64(expiry.timeIntervalSince1970))"
    }

    static func validate(hostHints: [String]) throws {
        guard (1...maxHostHints).contains(hostHints.count) else { throw PairingError.malformedPayload("host hint count") }
        for h in hostHints {
            guard (1...maxHostHintLength).contains(h.utf8.count),
                  h.utf8.allSatisfy({ ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x61 && $0 <= 0x7A)
                      || $0 == 0x2E || $0 == 0x2D || $0 == 0x5F || $0 == 0x3A || $0 == 0x25 })
            else { throw PairingError.malformedPayload("host hint") }
        }
    }

    /// Parses and validates a scanned string. Throws `.expired` for a stale code.
    public static func parse(_ string: String, now: Date = Date()) throws -> PairingQRPayload {
        guard string.utf8.count <= maxEncodedLength else { throw PairingError.malformedPayload("too long") }
        let parts = string.split(separator: ";", omittingEmptySubsequences: false)
        guard parts.count == 7, parts[0] == scheme else { throw PairingError.malformedPayload("shape") }
        var fields: [String: String] = [:]
        for part in parts.dropFirst() {
            guard let eq = part.firstIndex(of: "=") else { throw PairingError.malformedPayload("field") }
            let key = String(part[..<eq]), value = String(part[part.index(after: eq)...])
            guard key.count == 1, fields[key] == nil else { throw PairingError.malformedPayload("field") }
            fields[key] = value
        }
        guard let h = fields["h"], let p = fields["p"], let k = fields["k"], let s = fields["s"], let n = fields["n"],
              let e = fields["e"], fields.count == 6
        else { throw PairingError.malformedPayload("missing field") }

        let hints = h.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        try validate(hostHints: hints)
        guard p.utf8.count <= 5, p.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }), let port = UInt16(p), port != 0 else {
            throw PairingError.malformedPayload("port")
        }
        guard let kd = Base64URL.decode(k, expectedCount: 32), let sd = Base64URL.decode(s, expectedCount: 16),
              let nd = Base64URL.decode(n, expectedCount: 16) else { throw PairingError.malformedPayload("base64") }
        guard e.utf8.count <= 12, !e.isEmpty, e.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }), let secs = Int64(e) else {
            throw PairingError.malformedPayload("expiry")
        }
        let expiry = Date(timeIntervalSince1970: TimeInterval(secs))
        guard expiry > now else { throw PairingError.expired }
        guard expiry.timeIntervalSince(now) <= maxLifetime else { throw PairingError.malformedPayload("expiry too far") }
        return PairingQRPayload(hostHints: hints, port: port, macSPKIHash: kd, secret: sd, nonce: nd, expiry: expiry)
    }
}
