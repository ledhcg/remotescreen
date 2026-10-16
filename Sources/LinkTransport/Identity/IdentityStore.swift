import CryptoKit
import Foundation
import Security

/// Where device identities live. The Keychain implementation is the real one; tests use `InMemoryIdentityStore`.
public protocol IdentityStore: Sendable {
    /// The stored certificate for `label`, if any. Never returns key material.
    func certificate(label: String) throws -> LinkCertificate?
    /// Stores key and certificate under `label`, replacing any previous identity with that label.
    func save(_ identity: LinkIdentity, label: String) throws
    /// Re-issues the certificate for the stored key (same SPKI, so pins stay valid) and stores it.
    func renewCertificate(label: String, role: LinkRole, now: Date, validityDays: Int) throws -> LinkCertificate
    /// The `SecIdentity` Network.framework needs for TLS.
    func secIdentity(label: String) throws -> SecIdentity
    func remove(label: String) throws
    /// Creates a new identity whose private key is generated inside the store and never leaves it. Returns nil when the
    /// store cannot do that, in which case `loadOrCreate` generates the key in memory and calls `save`.
    func createInPlace(role: LinkRole, label: String, now: Date) throws -> LinkCertificate?
}

public extension IdentityStore {
    /// Returns the existing certificate, renewing it past 80 % of its validity, or creates a new identity.
    func loadOrCreate(role: LinkRole, label: String, now: Date = Date()) throws -> LinkCertificate {
        if let existing = try certificate(label: label) {
            if !existing.needsRotation(now: now) { return existing }
            return try renewCertificate(label: label, role: role, now: now, validityDays: LinkCertificateBuilder.defaultValidityDays)
        }
        if let created = try createInPlace(role: role, label: label, now: now) { return created }
        let identity = try LinkIdentity.generate(role: role, now: now)
        try save(identity, label: label)
        return identity.certificate
    }

    func createInPlace(role: LinkRole, label: String, now: Date) throws -> LinkCertificate? { nil }
}

/// Test double. Holds keys in memory; cannot produce a `SecIdentity` (that needs a keychain).
public final class InMemoryIdentityStore: IdentityStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: LinkIdentity] = [:]

    public init() {}

    public func certificate(label: String) throws -> LinkCertificate? {
        lock.withLock { items[label]?.certificate }
    }

    public func save(_ identity: LinkIdentity, label: String) throws {
        lock.withLock { items[label] = identity }
    }

    public func renewCertificate(label: String, role: LinkRole, now: Date, validityDays: Int) throws -> LinkCertificate {
        let old = try lock.withLock { () -> LinkIdentity in
            guard let i = items[label] else { throw LinkIdentityError.notFound }
            return i
        }
        let renewed = try old.renewed(now: now, validityDays: validityDays)
        lock.withLock { items[label] = renewed }
        return renewed.certificate
    }

    public func secIdentity(label: String) throws -> SecIdentity {
        throw LinkIdentityError.unsupported("in-memory store has no SecIdentity")
    }

    public func remove(label: String) throws {
        _ = lock.withLock { items.removeValue(forKey: label) }
    }
}

/// Keychain-backed store. The private key is imported once as a non-exportable-by-design keychain item
/// (`AfterFirstUnlockThisDeviceOnly`) and afterwards only used through `SecKey` (TLS, certificate signing).
/// Key bytes are never logged or returned.
///
/// Needs a signed app with Keychain access (data-protection keychain). Plain `swift test` binaries usually cannot use it;
/// see the optional test guarded by `SCREON_KEYCHAIN_TESTS`.
public struct KeychainIdentityStore: IdentityStore {
    /// Application-specific prefix for key tags, e.g. `app.screon.link.identity`.
    public let tagPrefix: String
    /// iOS and signed apps with a keychain access group: the data-protection keychain, items `AfterFirstUnlockThisDeviceOnly`.
    /// `false` (the Mac helper, Developer ID without a provisioning profile): the file-based login keychain. There
    /// `kSecAttrAccessible` must not be set: macOS treats it as a request for the data-protection keychain and fails with
    /// errSecMissingEntitlement (-34018). File-keychain items never sync, so they stay on this Mac.
    public let useDataProtectionKeychain: Bool

    public init(tagPrefix: String = "app.screon.link.identity", useDataProtectionKeychain: Bool = true) {
        self.tagPrefix = tagPrefix
        self.useDataProtectionKeychain = useDataProtectionKeychain
    }

    private func tag(_ label: String) -> Data { Data("\(tagPrefix).\(label)".utf8) }

    private func base(_ cls: CFString, _ label: String) -> [String: Any] {
        var q: [String: Any] = [kSecClass as String: cls]
        if useDataProtectionKeychain { q[kSecUseDataProtectionKeychain as String] = true }
        if cls == kSecClassKey { q[kSecAttrApplicationTag as String] = tag(label) } else { q[kSecAttrLabel as String] = "\(tagPrefix).\(label)" }
        return q
    }

    private func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else { throw LinkIdentityError.keychain(status) }
    }

    public func certificate(label: String) throws -> LinkCertificate? {
        guard let cert = try certificateRef(label: label) else { return nil }
        return try LinkCertificate(der: SecCertificateCopyData(cert) as Data)
    }

    /// The file-based keychain ignores `kSecAttrLabel` on certificates, so there the certificate is found through the
    /// public-key hash of the key stored under `label` (keys keep their application tag in both keychains).
    private func certificateQuery(label: String) throws -> [String: Any]? {
        guard !useDataProtectionKeychain else { return base(kSecClassCertificate, label) }
        guard let key = try? privateKey(label: label), let publicKey = SecKeyCopyPublicKey(key),
              let raw = SecKeyCopyExternalRepresentation(publicKey, nil) as Data? else { return nil }
        return [
            kSecClass as String: kSecClassCertificate,
            kSecAttrPublicKeyHash as String: Data(Insecure.SHA1.hash(data: raw)),
        ]
    }

    private func certificateRef(label: String) throws -> SecCertificate? {
        guard var q = try certificateQuery(label: label) else { return nil }
        q[kSecReturnRef as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        try check(status)
        guard let ref = out, CFGetTypeID(ref) == SecCertificateGetTypeID() else { return nil }
        return unsafeBitCast(ref, to: SecCertificate.self)
    }

    public func save(_ identity: LinkIdentity, label: String) throws {
        try remove(label: label)
        let attrs: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecAttrKeySizeInBits as String: 256,
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(identity.privateKey.x963Representation as CFData, attrs as CFDictionary, &error) else {
            throw LinkIdentityError.keychain(Int32(CFErrorGetCode(error?.takeRetainedValue())))
        }
        var keyItem = base(kSecClassKey, label)
        keyItem[kSecValueRef as String] = key
        keyItem[kSecAttrLabel as String] = "\(tagPrefix).\(label)"
        if useDataProtectionKeychain { keyItem[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly }
        keyItem[kSecAttrIsPermanent as String] = true
        try check(SecItemAdd(keyItem as CFDictionary, nil))
        try addCertificate(identity.certificate, label: label)
    }

    private func addCertificate(_ cert: LinkCertificate, label: String) throws {
        guard let sec = SecCertificateCreateWithData(nil, cert.der as CFData) else {
            throw LinkIdentityError.malformedCertificate("rejected by Security.framework")
        }
        var item = base(kSecClassCertificate, label)
        item[kSecValueRef as String] = sec
        if useDataProtectionKeychain { item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly }
        try check(SecItemAdd(item as CFDictionary, nil))
    }

    private func privateKey(label: String) throws -> SecKey {
        var q = base(kSecClassKey, label)
        q[kSecAttrKeyClass as String] = kSecAttrKeyClassPrivate
        q[kSecReturnRef as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { throw LinkIdentityError.notFound }
        try check(status)
        guard let ref = out, CFGetTypeID(ref) == SecKeyGetTypeID() else { throw LinkIdentityError.notFound }
        return unsafeBitCast(ref, to: SecKey.self)
    }

    public func renewCertificate(label: String, role: LinkRole, now: Date, validityDays: Int) throws -> LinkCertificate {
        let key = try privateKey(label: label)
        guard let old = try certificate(label: label) else { throw LinkIdentityError.notFound }
        let publicKey = try P256.Signing.PublicKey(derRepresentation: old.spkiDER)
        let der = try LinkCertificateBuilder.build(publicKey: publicKey, role: role, now: now, validityDays: validityDays) { tbs in
            var error: Unmanaged<CFError>?
            guard let sig = SecKeyCreateSignature(key, .ecdsaSignatureMessageX962SHA256, tbs as CFData, &error) else {
                throw LinkIdentityError.keychain(Int32(CFErrorGetCode(error?.takeRetainedValue())))
            }
            return sig as Data
        }
        let renewed = try LinkCertificate(der: der)
        // Replace the certificate item only; the key (and thus the pin) stays.
        try removeCertificate(label: label)
        try addCertificate(renewed, label: label)
        return renewed
    }

    public func secIdentity(label: String) throws -> SecIdentity {
        if !useDataProtectionKeychain {
#if os(macOS)
            guard let cert = try certificateRef(label: label) else { throw LinkIdentityError.notFound }
            var identity: SecIdentity?
            let status = SecIdentityCreateWithCertificate(nil, cert, &identity)
            if status == errSecItemNotFound { throw LinkIdentityError.notFound }
            try check(status)
            guard let identity else { throw LinkIdentityError.notFound }
            return identity
#else
            throw LinkIdentityError.unsupported("the file-based keychain exists only on macOS")
#endif
        }
        var q = base(kSecClassIdentity, label)
        q[kSecReturnRef as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { throw LinkIdentityError.notFound }
        try check(status)
        guard let ref = out, CFGetTypeID(ref) == SecIdentityGetTypeID() else { throw LinkIdentityError.notFound }
        return unsafeBitCast(ref, to: SecIdentity.self)
    }

    /// The file-based keychain (macOS, `useDataProtectionKeychain == false`) refuses a key imported with
    /// `SecKeyCreateWithData` (errSecMissingEntitlement, -34018), so there the key is generated by the keychain itself
    /// and the certificate is signed through it. The data-protection keychain keeps the import path (`save`).
    public func createInPlace(role: LinkRole, label: String, now: Date) throws -> LinkCertificate? {
        guard !useDataProtectionKeychain else { return nil }
        try remove(label: label)
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: true,
                kSecAttrApplicationTag as String: tag(label),
                kSecAttrLabel as String: "\(tagPrefix).\(label)",
            ] as [String: Any],
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            throw LinkIdentityError.keychain(Int32(CFErrorGetCode(error?.takeRetainedValue())))
        }
        guard let publicKey = SecKeyCopyPublicKey(key),
              let raw = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else {
            try? remove(label: label)
            throw LinkIdentityError.keychain(Int32(CFErrorGetCode(error?.takeRetainedValue())))
        }
        do {
            let der = try LinkCertificateBuilder.build(
                publicKey: try P256.Signing.PublicKey(x963Representation: raw), role: role, now: now,
                validityDays: LinkCertificateBuilder.defaultValidityDays
            ) { tbs in
                var signError: Unmanaged<CFError>?
                guard let sig = SecKeyCreateSignature(key, .ecdsaSignatureMessageX962SHA256, tbs as CFData, &signError) else {
                    throw LinkIdentityError.keychain(Int32(CFErrorGetCode(signError?.takeRetainedValue())))
                }
                return sig as Data
            }
            let certificate = try LinkCertificate(der: der)
            try addCertificate(certificate, label: label)
            return certificate
        } catch {
            try? remove(label: label)
            throw error
        }
    }

    public func remove(label: String) throws {
        try removeCertificate(label: label)  // before the key: the file keychain finds the certificate through the key
        let status = SecItemDelete(base(kSecClassKey, label) as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound { throw LinkIdentityError.keychain(status) }
    }

    private func removeCertificate(label: String) throws {
        guard let q = try certificateQuery(label: label) else { return }
        let status = SecItemDelete(q as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound { throw LinkIdentityError.keychain(status) }
    }
}
