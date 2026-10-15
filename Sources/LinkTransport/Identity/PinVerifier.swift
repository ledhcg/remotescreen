import Foundation
import Security

public enum PinError: Error, Equatable {
    case noCertificate
    case malformedCertificate
    case mismatch
}

/// Trust decision for a peer certificate. There is no CA trust: the SPKI pin is the only authority.
public enum PinPolicy: Sendable, Equatable {
    /// Accept only a leaf whose SPKI SHA-256 equals this 32-byte pin.
    case pinned(Data)
    /// Pairing: accept any well-formed leaf and report its hash; the pairing proof binds that hash afterwards.
    case pairing
}

public enum PinVerifier {
    /// Evaluates a DER leaf certificate and returns its SPKI hash, or throws.
    public static func evaluate(leafDER: Data, policy: PinPolicy) throws -> Data {
        let cert: LinkCertificate
        do { cert = try LinkCertificate(der: leafDER) } catch { throw PinError.malformedCertificate }
        switch policy {
        case .pairing:
            return cert.spkiHash
        case .pinned(let expected):
            guard constantTimeEqual(cert.spkiHash, expected) else { throw PinError.mismatch }
            return cert.spkiHash
        }
    }

    /// Leaf certificate DER from a `SecTrust` chain (the peer's certificate is first).
    public static func leafDER(from trust: SecTrust) throws -> Data {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first else {
            throw PinError.noCertificate
        }
        return SecCertificateCopyData(leaf) as Data
    }

    public static func evaluate(trust: SecTrust, policy: PinPolicy) throws -> Data {
        try evaluate(leafDER: leafDER(from: trust), policy: policy)
    }
}
