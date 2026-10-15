import CryptoKit
import Foundation

/// Which side of the link a certificate belongs to. Appears in the (non-personal) certificate common name.
public enum LinkRole: String, Sendable {
    case helper = "Helper"
    case ipad = "iPad"
}

/// Hand-built, self-signed X.509 v3 certificate for a P-256 key (ecdsa-with-SHA256).
public enum LinkCertificateBuilder {
    /// RFC 5480 / RFC 5758 / RFC 5280 OIDs.
    static let ecdsaSHA256Alg = DER.sequence(DER.oid([1, 2, 840, 10045, 4, 3, 2]))
    static let oidCommonName = DER.oid([2, 5, 4, 3])
    static let oidSubjectKeyIdentifier = DER.oid([2, 5, 29, 14])
    static let oidKeyUsage = DER.oid([2, 5, 29, 15])
    static let oidBasicConstraints = DER.oid([2, 5, 29, 19])

    /// Maximum validity we ever issue (Apple platforms reject server certificates valid for longer than 825 days).
    public static let maxValidityDays = 825
    public static let defaultValidityDays = 800

    /// Builds and signs a certificate. `sign` receives the TBS bytes and returns a DER ECDSA signature, so the private
    /// key can stay inside the Keychain.
    public static func build(
        publicKey: P256.Signing.PublicKey,
        role: LinkRole,
        now: Date,
        validityDays: Int,
        sign: (Data) throws -> Data
    ) throws -> Data {
        precondition((1...maxValidityDays).contains(validityDays))
        let spki = [UInt8](publicKey.derRepresentation)
        let spkiHash = SPKIHash.hash(spki: Data(spki))
        let shortID = spkiHash.prefix(4).map { String(format: "%02x", $0) }.joined()
        let name = DER.sequence(DER.set(DER.sequence(oidCommonName, DER.utf8String("Screon \(role.rawValue) \(shortID)"))))

        var serial = [UInt8](try LinkRandom.bytes(16))
        serial[0] = (serial[0] & 0x7F) | 0x40  // positive, never needs padding or stripping

        let notBefore = now.addingTimeInterval(-3600)
        let notAfter = now.addingTimeInterval(TimeInterval(validityDays) * 86_400)

        // KeyUsage: BIT STRING 0b1000_0000 with 7 unused bits = digitalSignature only.
        let keyUsage = DER.sequence(oidKeyUsage, DER.boolean(true), DER.octetString(DER.bitString([0x80], unusedBits: 7)))
        let basic = DER.sequence(oidBasicConstraints, DER.boolean(true), DER.octetString(DER.sequence()))
        let ski = DER.sequence(
            oidSubjectKeyIdentifier,
            DER.octetString(DER.octetString([UInt8](spkiHash.prefix(20)))))
        let extensions = DER.explicit(3, DER.sequence(basic, keyUsage, ski))

        let tbs = DER.sequence(
            DER.explicit(0, DER.integer(2)),
            DER.tlv(DER.integerTag, serial),
            ecdsaSHA256Alg,
            name,
            DER.sequence(DER.time(notBefore), DER.time(notAfter)),
            name,
            spki,
            extensions)
        let signature = [UInt8](try sign(Data(tbs)))
        return Data(DER.sequence(tbs, ecdsaSHA256Alg, DER.bitString(signature)))
    }
}

/// A device identity: P-256 signing key plus its self-signed certificate. The key never leaves this value except
/// through `IdentityStore.save`, which places it in the Keychain.
public struct LinkIdentity: Sendable {
    public let role: LinkRole
    public let privateKey: P256.Signing.PrivateKey
    public let certificate: LinkCertificate

    /// SHA-256 over the certificate's SubjectPublicKeyInfo DER.
    public var spkiHash: Data { certificate.spkiHash }
    public var certificateDER: Data { certificate.der }

    /// Generates a fresh key and certificate. Test identities must be generated per run, never checked in.
    public static func generate(role: LinkRole, now: Date = Date(), validityDays: Int = LinkCertificateBuilder.defaultValidityDays)
        throws -> LinkIdentity
    {
        try issue(role: role, key: P256.Signing.PrivateKey(), now: now, validityDays: validityDays)
    }

    /// Re-issues the certificate for the same key, so peers' SPKI pins stay valid across rotation.
    public func renewed(now: Date = Date(), validityDays: Int = LinkCertificateBuilder.defaultValidityDays) throws -> LinkIdentity {
        try Self.issue(role: role, key: privateKey, now: now, validityDays: validityDays)
    }

    public func needsRotation(now: Date = Date()) -> Bool { certificate.needsRotation(now: now) }

    private static func issue(role: LinkRole, key: P256.Signing.PrivateKey, now: Date, validityDays: Int) throws -> LinkIdentity {
        let der = try LinkCertificateBuilder.build(publicKey: key.publicKey, role: role, now: now, validityDays: validityDays) {
            try key.signature(for: $0).derRepresentation
        }
        return LinkIdentity(role: role, privateKey: key, certificate: try LinkCertificate(der: der))
    }
}
