import CryptoKit
import Foundation
import LinkProtocol
import LinkTransport
import Security

/// File-based identity for the mock (never the login keychain): the key and certificate live in `--identity-dir`, or only
/// in memory when none is given. The TLS identity is assembled in memory with `SecIdentityCreate`, the same approach the
/// LinkTransport tests use.
enum MockIdentity {
    private typealias Create = @convention(c) (CFAllocator?, SecCertificate, SecKey) -> Unmanaged<SecIdentity>?

    static func make(role: LinkRole, directory: URL?) throws -> LinkSecIdentity {
        let name = role == .helper ? "helper" : "ipad"
        if let directory {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let keyURL = directory.appendingPathComponent("\(name).key")
            let certURL = directory.appendingPathComponent("\(name).cer")
            if let keyData = try? Data(contentsOf: keyURL), let der = try? Data(contentsOf: certURL),
                let key = try? P256.Signing.PrivateKey(rawRepresentation: keyData),
                let cert = try? LinkCertificate(der: der), !cert.needsRotation(now: Date())
            {
                return try secIdentity(key: key, der: der)
            }
            let fresh = try LinkIdentity.generate(role: role)
            try fresh.privateKey.rawRepresentation.write(to: keyURL, options: .atomic)
            try fresh.certificateDER.write(to: certURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyURL.path)
            return try secIdentity(key: fresh.privateKey, der: fresh.certificateDER)
        }
        let fresh = try LinkIdentity.generate(role: role)
        return try secIdentity(key: fresh.privateKey, der: fresh.certificateDER)
    }

    private static func secIdentity(key: P256.Signing.PrivateKey, der: Data) throws -> LinkSecIdentity {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "SecIdentityCreate") else {
            throw MockError.message("SecIdentityCreate is unavailable on this system")
        }
        let create = unsafeBitCast(sym, to: Create.self)
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecAttrKeySizeInBits as String: 256,
        ]
        guard let secKey = SecKeyCreateWithData(key.x963Representation as CFData, attributes as CFDictionary, nil),
            let cert = SecCertificateCreateWithData(nil, der as CFData),
            let identity = create(nil, cert, secKey)?.takeRetainedValue()
        else { throw MockError.message("cannot build a TLS identity") }
        return LinkSecIdentity(identity)
    }
}

/// Paired iPads, persisted as JSON next to the mock identity (hash and name only, nothing secret).
final class FilePairedDeviceStore: PairedDeviceStore, @unchecked Sendable {
    private let lock = NSLock()
    private var devices: [Data: PairedDevice] = [:]
    private let url: URL?

    init(directory: URL?) {
        url = directory?.appendingPathComponent("paired-devices.json")
        if let url, let data = try? Data(contentsOf: url) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            if let list = try? decoder.decode([PairedDevice].self, from: data) {
                for d in list { devices[d.spkiHash] = d }
            }
        }
    }

    func device(spkiHash: Data) -> PairedDevice? { lock.withLock { devices[spkiHash] } }
    func all() -> [PairedDevice] { lock.withLock { devices.values.sorted { $0.pairedAt < $1.pairedAt } } }

    func add(_ device: PairedDevice) throws {
        try lock.withLock {
            guard devices[device.spkiHash] != nil || devices.count < InMemoryPairedDeviceStore.maxDevices else {
                throw PairedStoreError.full
            }
            devices[device.spkiHash] = device
            try persist()
        }
    }

    @discardableResult func revoke(spkiHash: Data) throws -> Bool {
        try lock.withLock {
            let removed = devices.removeValue(forKey: spkiHash) != nil
            try persist()
            return removed
        }
    }

    private func persist() throws {
        guard let url else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(Array(devices.values)).write(to: url, options: .atomic)
    }
}
