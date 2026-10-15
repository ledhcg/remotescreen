import CryptoKit
import Foundation
import Security
import Testing
@testable import LinkTransport

private func hex(_ s: String) -> Data {
    var d = Data()
    var i = s.startIndex
    while i < s.endIndex {
        let j = s.index(i, offsetBy: 2)
        d.append(UInt8(s[i..<j], radix: 16)!)
        i = j
    }
    return d
}

@Suite struct IdentityTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func certificateParsesWithSecurityFramework() throws {
        let id = try LinkIdentity.generate(role: .helper, now: now)
        let sec = try #require(SecCertificateCreateWithData(nil, id.certificateDER as CFData))
        let key = try #require(SecCertificateCopyKey(sec))
        let ext = try #require(SecKeyCopyExternalRepresentation(key, nil) as Data?)
        #expect(ext.count == 65)
        #expect(ext == id.privateKey.publicKey.x963Representation)
        let summary = try #require(SecCertificateCopySubjectSummary(sec) as String?)
        #expect(summary.hasPrefix("Screon Helper "))
    }

    @Test func signatureVerifiesOverTBS() throws {
        let id = try LinkIdentity.generate(role: .ipad, now: now)
        let c = id.certificate
        let pub = try P256.Signing.PublicKey(derRepresentation: c.spkiDER)
        let sig = try P256.Signing.ECDSASignature(derRepresentation: c.signatureDER)
        #expect(pub.isValidSignature(sig, for: c.tbsDER))
        var tampered = c.tbsDER
        tampered[tampered.count - 1] ^= 1
        #expect(!pub.isValidSignature(sig, for: tampered))
    }

    @Test func spkiHashMatchesIndependentComputation() throws {
        let id = try LinkIdentity.generate(role: .helper, now: now)
        let sec = try #require(SecCertificateCreateWithData(nil, id.certificateDER as CFData))
        let key = try #require(SecCertificateCopyKey(sec))
        let x963 = try #require(SecKeyCopyExternalRepresentation(key, nil) as Data?)
        // Standard P-256 SubjectPublicKeyInfo prefix (id-ecPublicKey, prime256v1, BIT STRING of 65 bytes).
        let prefix = hex("3059301306072a8648ce3d020106082a8648ce3d030107034200")
        #expect(id.spkiHash == Data(SHA256.hash(data: prefix + x963)))
        #expect(id.certificate.spkiDER == prefix + x963)
    }

    @Test func extensionsAndValidity() throws {
        let id = try LinkIdentity.generate(role: .helper, now: now)
        let c = id.certificate
        var top = try DERReader(c.der)
        let cert = top.reader(for: try top.next())
        var certR = cert
        let tbsE = try certR.next()
        var t = top.reader(for: tbsE)
        _ = try t.next()  // version
        let serial = try t.next()
        #expect(serial.content.count == 16)
        #expect(top.bytes[serial.content.lowerBound] & 0x80 == 0)
        _ = try t.next(); _ = try t.next(); _ = try t.next(); _ = try t.next(); _ = try t.next()
        let exts = try t.next()
        #expect(exts.tag == 0xA3)
        var er = top.reader(for: exts)
        var seq = top.reader(for: try er.next())
        var oids: [[UInt8]] = []
        var keyUsageBits: [UInt8]?
        var keyUsageCritical = false
        var basicConstraints: [UInt8]?
        while !seq.isAtEnd {
            let ext = try seq.next()
            var r = top.reader(for: ext)
            let oid = try r.next()
            let oidBytes = Array(top.bytes[oid.content])
            oids.append(oidBytes)
            var critical = false
            var value = try r.next()
            if value.tag == DER.booleanTag { critical = top.bytes[value.content.lowerBound] == 0xFF; value = try r.next() }
            if oidBytes == [0x55, 0x1D, 0x0F] {
                keyUsageCritical = critical
                keyUsageBits = Array(top.bytes[value.content])
            }
            if oidBytes == [0x55, 0x1D, 0x13] { basicConstraints = Array(top.bytes[value.content]) }
        }
        #expect(oids.count == 3)
        #expect(keyUsageCritical)
        #expect(keyUsageBits == [0x03, 0x02, 0x07, 0x80])  // digitalSignature only
        #expect(basicConstraints == [0x30, 0x00])  // CA:false
        #expect(c.notBefore == now.addingTimeInterval(-3600))
        let days = c.notAfter.timeIntervalSince(now) / 86_400
        #expect(days <= 825 && days > 700)
    }

    @Test func serialsDiffer() throws {
        let a = try LinkIdentity.generate(role: .helper, now: now)
        let b = try LinkIdentity.generate(role: .helper, now: now)
        #expect(a.certificateDER != b.certificateDER)
        #expect(a.spkiHash != b.spkiHash)
    }

    @Test func rotationAtEightyPercent() throws {
        let id = try LinkIdentity.generate(role: .helper, now: now, validityDays: 100)
        let c = id.certificate
        let total = c.notAfter.timeIntervalSince(c.notBefore)
        #expect(!id.needsRotation(now: c.notBefore.addingTimeInterval(total * 0.79)))
        #expect(id.needsRotation(now: c.notBefore.addingTimeInterval(total * 0.81)))
        #expect(id.needsRotation(now: c.notAfter.addingTimeInterval(1)))
    }

    @Test func renewalKeepsThePin() throws {
        let id = try LinkIdentity.generate(role: .helper, now: now, validityDays: 100)
        let later = now.addingTimeInterval(90 * 86_400)
        let renewed = try id.renewed(now: later)
        #expect(renewed.spkiHash == id.spkiHash)
        #expect(renewed.certificateDER != id.certificateDER)
        #expect(!renewed.needsRotation(now: later))
    }

    @Test func storeLoadOrCreateAndRotate() throws {
        let store = InMemoryIdentityStore()
        let first = try store.loadOrCreate(role: .ipad, label: "main", now: now)
        let again = try store.loadOrCreate(role: .ipad, label: "main", now: now.addingTimeInterval(86_400))
        #expect(first == again)
        let far = now.addingTimeInterval(700 * 86_400)
        let rotated = try store.loadOrCreate(role: .ipad, label: "main", now: far)
        #expect(rotated.spkiHash == first.spkiHash)
        #expect(rotated != first)
        #expect(throws: LinkIdentityError.self) { try store.secIdentity(label: "main") }
        try store.remove(label: "main")
        #expect(try store.certificate(label: "main") == nil)
    }

    @Test func pinVerification() throws {
        let id = try LinkIdentity.generate(role: .helper, now: now)
        let h = try PinVerifier.evaluate(leafDER: id.certificateDER, policy: .pinned(id.spkiHash))
        #expect(h == id.spkiHash)
        #expect(try PinVerifier.evaluate(leafDER: id.certificateDER, policy: .pairing) == id.spkiHash)
        let other = try LinkIdentity.generate(role: .helper, now: now)
        #expect(throws: PinError.mismatch) { try PinVerifier.evaluate(leafDER: other.certificateDER, policy: .pinned(id.spkiHash)) }
        #expect(throws: PinError.malformedCertificate) { try PinVerifier.evaluate(leafDER: Data([1, 2, 3]), policy: .pairing) }
        #expect(throws: PinError.malformedCertificate) { try PinVerifier.evaluate(leafDER: Data(), policy: .pairing) }
    }

    @Test func pinVerificationFromSecTrust() throws {
        let id = try LinkIdentity.generate(role: .helper, now: now)
        let sec = try #require(SecCertificateCreateWithData(nil, id.certificateDER as CFData))
        var trust: SecTrust?
        #expect(SecTrustCreateWithCertificates(sec, SecPolicyCreateBasicX509(), &trust) == errSecSuccess)
        let t = try #require(trust)
        #expect(try PinVerifier.evaluate(trust: t, policy: .pinned(id.spkiHash)) == id.spkiHash)
    }

    @Test func certificateParserRejectsTruncationAndGarbage() throws {
        let der = try LinkIdentity.generate(role: .helper, now: now).certificateDER
        for n in stride(from: 0, to: der.count, by: 7) {
            #expect(throws: LinkIdentityError.self) { try LinkCertificate(der: der.prefix(n)) }
        }
        #expect(throws: LinkIdentityError.self) { try LinkCertificate(der: Data(repeating: 0xFF, count: 64)) }
        #expect(throws: LinkIdentityError.self) { try LinkCertificate(der: Data(repeating: 0x30, count: 100_000)) }
        // Length claiming more than the input holds.
        #expect(throws: LinkIdentityError.self) { try LinkCertificate(der: Data([0x30, 0x84, 0xFF, 0xFF, 0xFF, 0xFF])) }
        var trailing = der
        trailing.append(0)
        #expect(throws: LinkIdentityError.self) { try LinkCertificate(der: trailing) }
    }

    @Test func derWriterPrimitives() {
        #expect(DER.length(5) == [5])
        #expect(DER.length(128) == [0x81, 0x80])
        #expect(DER.length(300) == [0x82, 0x01, 0x2C])
        #expect(DER.integer(0) == [2, 1, 0])
        #expect(DER.integer(128) == [2, 2, 0, 0x80])
        #expect(DER.oid([1, 2, 840, 10045, 3, 1, 7]) == [6, 8, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 3, 1, 7])
        #expect(DER.oid([2, 5, 4, 3]) == [6, 3, 0x55, 4, 3])
        #expect(DER.time(Date(timeIntervalSince1970: 0)) == DER.tlv(DER.utcTimeTag, Array("700101000000Z".utf8)))
        #expect(DER.time(Date(timeIntervalSince1970: 2_600_000_000)).first == DER.generalizedTimeTag)
    }

    /// Optional: needs a keychain a test binary can use (signed host or `SCREON_KEYCHAIN_TESTS=1` with a login keychain).
    /// Skipped by default so `swift test` never prompts.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SCREON_KEYCHAIN_TESTS"] == "1"))
    func keychainStoreRoundTrip() throws {
        let store = KeychainIdentityStore(tagPrefix: "app.screon.link.test", useDataProtectionKeychain: false)
        let label = "test-\(UUID().uuidString)"
        defer { try? store.remove(label: label) }
        let id = try LinkIdentity.generate(role: .helper)
        try store.save(id, label: label)
        #expect(try store.certificate(label: label) == id.certificate)
        _ = try store.secIdentity(label: label)
        let renewed = try store.renewCertificate(label: label, role: .helper, now: Date(), validityDays: 100)
        #expect(renewed.spkiHash == id.spkiHash)
    }
}
