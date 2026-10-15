import Foundation
import Security
@testable import LinkTransport

/// Test-only: builds a `SecIdentity` from a generated `LinkIdentity` for TLS in `swift test` (macOS only). Plain test binaries
/// cannot use the data-protection keychain, so there are two ways:
///
/// 1. `SoftwareIdentity`: pairs an in-memory (non-keychain) `SecKey` with the certificate through `SecIdentityCreate`, a
///    Security.framework function that is exported but not declared in the public headers. Test code only, looked up with
///    `dlsym`; signing takes ~0.1 ms.
/// 2. Fallback if that symbol is missing: a throw-away file keychain in a temporary directory (`TempKeychain`). Correct but
///    slow (~120 ms per signature, every TLS handshake signs twice), so the suite takes several times longer.
///
/// Keys are generated per run; nothing here is a fixture, and nothing from here is used by the library.
enum SoftwareIdentity {
    private typealias Create = @convention(c) (CFAllocator?, SecCertificate, SecKey) -> Unmanaged<SecIdentity>?

    static func make(for identity: LinkIdentity) -> SecIdentity? {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "SecIdentityCreate") else { return nil }  // RTLD_DEFAULT
        let create = unsafeBitCast(sym, to: Create.self)
        let attrs: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom, kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecAttrKeySizeInBits as String: 256,
        ]
        guard let key = SecKeyCreateWithData(identity.privateKey.x963Representation as CFData, attrs as CFDictionary, nil),
              let cert = SecCertificateCreateWithData(nil, identity.certificateDER as CFData)
        else { return nil }
        return create(nil, cert, key)?.takeRetainedValue()
    }
}

final class TempKeychain: @unchecked Sendable {
    private let directory: URL
    private var keychain: SecKeychain?

    /// Creates a temporary file keychain. Only needed when `SoftwareIdentity` is unavailable.
    init?() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("screon-test-\(UUID().uuidString)")
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) } catch { return nil }
        let path = directory.appendingPathComponent("test.keychain").path
        var kc: SecKeychain?
        let password = "screon-test"
        let status = password.withCString { SecKeychainCreate(path, UInt32(strlen($0)), $0, false, nil, &kc) }
        guard status == errSecSuccess, let kc else { try? FileManager.default.removeItem(at: directory); return nil }
        keychain = kc
    }

    func cleanUp() {
        if let keychain { SecKeychainDelete(keychain) }
        keychain = nil
        try? FileManager.default.removeItem(at: directory)
    }

    /// Imports the key (SEC1 PEM) and certificate (PEM), then looks the pair up as an identity.
    func secIdentity(for identity: LinkIdentity) throws -> SecIdentity {
        if let soft = SoftwareIdentity.make(for: identity) { return soft }
        guard let keychain else { throw LinkIdentityError.unsupported("no keychain") }
        func importPEM(_ pem: String, type: SecExternalItemType) throws {
            var format = SecExternalFormat.formatUnknown
            var itemType = type
            var items: CFArray?
            let status = SecItemImport(Data(pem.utf8) as CFData, nil, &format, &itemType, [], nil, keychain, &items)
            guard status == errSecSuccess else { throw LinkIdentityError.keychain(status) }
        }
        // SEC1 "EC PRIVATE KEY" (RFC 5915): SEQUENCE { 1, OCTET STRING d, [0] OID prime256v1, [1] BIT STRING point }.
        let sec1 = DER.sequence(
            DER.integer(1), DER.octetString([UInt8](identity.privateKey.rawRepresentation)),
            DER.explicit(0, DER.oid([1, 2, 840, 10045, 3, 1, 7])),
            DER.explicit(1, DER.bitString([UInt8](identity.privateKey.publicKey.x963Representation))))
        let keyB64 = Data(sec1).base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        try importPEM("-----BEGIN EC PRIVATE KEY-----\n\(keyB64)\n-----END EC PRIVATE KEY-----\n", type: .itemTypePrivateKey)
        let certB64 = identity.certificateDER.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        try importPEM("-----BEGIN CERTIFICATE-----\n\(certB64)\n-----END CERTIFICATE-----\n", type: .itemTypeCertificate)
        guard let cert = SecCertificateCreateWithData(nil, identity.certificateDER as CFData) else {
            throw LinkIdentityError.unsupported("certificate")
        }
        var out: SecIdentity?
        let st = SecIdentityCreateWithCertificate(keychain, cert, &out)
        guard st == errSecSuccess, let out else { throw LinkIdentityError.keychain(st) }
        return out
    }
}
