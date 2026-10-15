import CryptoKit
import Foundation
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

final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var t: Date
    init(_ t: Date = Date(timeIntervalSince1970: 1_800_000_000)) { self.t = t }
    var now: Date { lock.withLock { t } }
    func advance(_ s: TimeInterval) { lock.withLock { t = t.addingTimeInterval(s) } }
    var clock: LinkClock { { [self] in now } }
}

@Suite struct PrimitiveVectorTests {
    @Test func hkdfRFC5869Case1() {
        let ikm = SymmetricKey(data: Data(repeating: 0x0b, count: 22))
        let salt = hex("000102030405060708090a0b0c")
        let info = hex("f0f1f2f3f4f5f6f7f8f9")
        let okm = HKDF<SHA256>.deriveKey(inputKeyMaterial: ikm, salt: salt, info: info, outputByteCount: 42)
        let bytes = okm.withUnsafeBytes { Data($0) }
        #expect(bytes == hex("3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865"))
    }

    @Test func hmacRFC4231Case2() {
        let mac = HMAC<SHA256>.authenticationCode(for: Data("what do ya want for nothing?".utf8), using: SymmetricKey(data: Data("Jefe".utf8)))
        #expect(Data(mac) == hex("5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843"))
    }

    @Test func proofKeyUsesDocumentedParameters() throws {
        let secret = Data(repeating: 1, count: 16), nonce = Data(repeating: 2, count: 16)
        let expected = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: secret), salt: nonce, info: Data("screon pair v1".utf8), outputByteCount: 32)
        #expect(PairingProof.key(secret: secret, nonce: nonce) == expected)
    }

    @Test func constantTimeEqualBasics() {
        #expect(constantTimeEqual(Data([1, 2]), Data([1, 2])))
        #expect(!constantTimeEqual(Data([1, 2]), Data([1, 3])))
        #expect(!constantTimeEqual(Data([1, 2]), Data([1])))
    }
}

@Suite struct QRPayloadTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func sample(expiry: TimeInterval = 300) throws -> PairingQRPayload {
        PairingQRPayload(
            hostHints: ["mac.local", "10.0.0.2"], port: 4433, macSPKIHash: try LinkRandom.bytes(32),
            secret: try LinkRandom.bytes(16), nonce: try LinkRandom.bytes(16), expiry: now.addingTimeInterval(expiry))
    }

    @Test func roundTrip() throws {
        let p = try sample()
        let s = try p.encoded()
        #expect(s.hasPrefix("screon-pair:v1;h=mac.local,10.0.0.2;p=4433;k="))
        #expect(try PairingQRPayload.parse(s, now: now) == p)
    }

    @Test func rejectsExpiredAndFarFuture() throws {
        let s = try sample().encoded()
        #expect(throws: PairingError.expired) { try PairingQRPayload.parse(s, now: now.addingTimeInterval(301)) }
        let far = try sample(expiry: 100_000).encoded()
        #expect(throws: PairingError.self) { try PairingQRPayload.parse(far, now: now) }
    }

    @Test func rejectsMalformed() throws {
        let good = try sample().encoded()
        let parts = good.split(separator: ";").map(String.init)
        func bad(_ s: String) {
            #expect(throws: PairingError.self) { try PairingQRPayload.parse(s, now: now) }
        }
        bad("")
        bad("screon-pair:v2;" + parts.dropFirst().joined(separator: ";"))
        for i in 1..<parts.count {  // each field missing
            var p = parts; p.remove(at: i); bad(p.joined(separator: ";"))
        }
        bad(good + ";x=1")  // unknown extra field
        bad(good + ";")
        bad(good.replacingOccurrences(of: ";p=4433", with: ";p=0"))
        bad(good.replacingOccurrences(of: ";p=4433", with: ";p=65536"))
        bad(good.replacingOccurrences(of: ";p=4433", with: ";p=-1"))
        bad(good.replacingOccurrences(of: "h=mac.local,10.0.0.2", with: "h="))
        bad(good.replacingOccurrences(of: "h=mac.local,10.0.0.2", with: "h=a,b,c,d,e"))
        bad(good.replacingOccurrences(of: "h=mac.local,10.0.0.2", with: "h=mac.local,,x"))
        bad(good.replacingOccurrences(of: "h=mac.local,10.0.0.2", with: "h=" + String(repeating: "a", count: 254)))
        bad(good.replacingOccurrences(of: "h=mac.local,10.0.0.2", with: "h=bad host"))
        bad(good + String(repeating: "A", count: 2000))
        // Bad base64: wrong alphabet, padding, wrong length, non-canonical trailing bits.
        let k = parts[3].dropFirst(2)
        bad(good.replacingOccurrences(of: String(k), with: String(k.dropLast()) + "="))
        bad(good.replacingOccurrences(of: String(k), with: String(k.dropLast())))
        bad(good.replacingOccurrences(of: String(k), with: String(k.dropLast()) + "+"))
        bad(good.replacingOccurrences(of: String(k), with: String(k.dropLast()) + "AA"))
        let s = parts[4].dropFirst(2)  // 22 chars; last char carries 2 unused bits
        let nonCanonical = s.dropLast() + (s.last == "B" ? "C" : "B")
        bad(good.replacingOccurrences(of: String(s), with: String(nonCanonical)))
        bad(good.replacingOccurrences(of: parts[6], with: "e=abc"))
        bad(good.replacingOccurrences(of: parts[6], with: "e=9999999999999999999"))
        bad(good.replacingOccurrences(of: parts[6], with: "e="))
    }

    @Test func duplicateFieldRejected() throws {
        let good = try sample().encoded()
        let parts = good.split(separator: ";").map(String.init)
        let dup = ([parts[0]] + [parts[1], parts[1], parts[3], parts[4], parts[5], parts[6]]).joined(separator: ";")
        #expect(throws: PairingError.self) { try PairingQRPayload.parse(dup, now: now) }
    }

    @Test func encodeValidatesInputs() throws {
        var p = try sample()
        p.secret = Data(count: 15)
        #expect(throws: PairingError.self) { try p.encoded() }
        p = try sample(); p.hostHints = []
        #expect(throws: PairingError.self) { try p.encoded() }
    }
}

@Suite struct ProofAndLedgerTests {
    let mac = Data(repeating: 0xAA, count: 32)
    let ipad = Data(repeating: 0xBB, count: 32)

    func proof(_ offer: PairingOffer, binding: PairingBinding, name: String = "Alice's iPad") throws -> Data {
        try PairingProof.mac(secret: offer.secret, nonce: offer.nonce, binding: binding, macSPKIHash: mac, ipadSPKIHash: ipad, deviceName: name)
    }

    func verify(_ m: Data, _ offer: PairingOffer, binding: PairingBinding, name: String = "Alice's iPad") -> Bool {
        PairingProof.verify(mac: m, secret: offer.secret, nonce: offer.nonce, binding: binding, macSPKIHash: mac, ipadSPKIHash: ipad, deviceName: name)
    }

    @Test func proofVerifiesAndDetectsTampering() throws {
        let clock = TestClock()
        let ledger = PairingSecretLedger(clock: clock.clock)
        let offer = try ledger.issue()
        let ex = PairingBinding.exporter(try LinkRandom.bytes(32))
        let m = try proof(offer, binding: ex)
        #expect(verify(m, offer, binding: ex))
        #expect(!verify(m, offer, binding: ex, name: "Mallory"))
        #expect(!verify(m, offer, binding: .exporter(try LinkRandom.bytes(32))))
        var flipped = m; flipped[0] ^= 1
        #expect(!verify(flipped, offer, binding: ex))
        #expect(!verify(m.dropLast(), offer, binding: ex))
        let wrong = PairingOffer(secret: try LinkRandom.bytes(16), nonce: offer.nonce, expiry: offer.expiry)
        #expect(!verify(m, wrong, binding: ex))
        // Swapped SPKI order must not verify.
        #expect(!PairingProof.verify(mac: m, secret: offer.secret, nonce: offer.nonce, binding: ex, macSPKIHash: ipad, ipadSPKIHash: mac, deviceName: "Alice's iPad"))
    }

    @Test func challengeVariantAndDomainSeparation() throws {
        let offer = PairingOffer(secret: try LinkRandom.bytes(16), nonce: try LinkRandom.bytes(16), expiry: .distantFuture)
        let chal = PairingBinding.helperChallenge(nonce: offer.nonce, challenge: try LinkRandom.bytes(32))
        let m = try proof(offer, binding: chal)
        #expect(verify(m, offer, binding: chal))
        #expect(!verify(m, offer, binding: .helperChallenge(nonce: offer.nonce, challenge: try LinkRandom.bytes(32))))
        // Field boundaries are unambiguous: moving bytes between name and next field changes the transcript.
        let t1 = try PairingProof.transcript(binding: chal, macSPKIHash: mac, ipadSPKIHash: ipad, deviceName: "ab")
        let t2 = try PairingProof.transcript(binding: chal, macSPKIHash: mac, ipadSPKIHash: ipad, deviceName: "a")
        #expect(t1 != t2)
        #expect(throws: PairingError.self) {
            try PairingProof.transcript(binding: chal, macSPKIHash: mac, ipadSPKIHash: ipad, deviceName: String(repeating: "x", count: 65))
        }
        #expect(throws: PairingError.self) { try PairingProof.transcript(binding: chal, macSPKIHash: mac, ipadSPKIHash: ipad, deviceName: "") }
    }

    @Test func transcriptEncodingIsExactlyAsDocumented() throws {
        let ex = Data(repeating: 1, count: 32)
        let t = try PairingProof.transcript(binding: .exporter(ex), macSPKIHash: mac, ipadSPKIHash: ipad, deviceName: "Hi")
        var expected = Data([0x01])
        expected.append(Data([0, 0, 0, 32])); expected.append(ex)
        expected.append(Data([0, 0, 0, 32])); expected.append(mac)
        expected.append(Data([0, 0, 0, 32])); expected.append(ipad)
        expected.append(Data([0, 0, 0, 2])); expected.append(Data("Hi".utf8))
        #expect(t == expected)
    }

    @Test func ledgerSuccessBurnsSecret() throws {
        let clock = TestClock()
        let ledger = PairingSecretLedger(clock: clock.clock)
        let offer = try ledger.issue()
        let ex = PairingBinding.exporter(try LinkRandom.bytes(32))
        let m = try proof(offer, binding: ex)
        try ledger.attempt(nonce: offer.nonce) { verify(m, $0, binding: ex) }
        #expect(throws: PairingError.unknownOrUsedSecret) { try ledger.attempt(nonce: offer.nonce) { verify(m, $0, binding: ex) } }
    }

    @Test func ledgerExpiry() throws {
        let clock = TestClock()
        let ledger = PairingSecretLedger(clock: clock.clock)
        let offer = try ledger.issue()
        clock.advance(299)
        #expect(throws: PairingError.invalidProof) { try ledger.attempt(nonce: offer.nonce) { _ in false } }
        clock.advance(2)
        #expect(throws: PairingError.unknownOrUsedSecret) { try ledger.attempt(nonce: offer.nonce) { _ in true } }
    }

    @Test func ledgerAttemptLimitPerSecret() throws {
        let clock = TestClock()
        let ledger = PairingSecretLedger(clock: clock.clock)
        let offer = try ledger.issue()
        #expect(throws: PairingError.invalidProof) { try ledger.attempt(nonce: offer.nonce) { _ in false } }
        #expect(throws: PairingError.invalidProof) { try ledger.attempt(nonce: offer.nonce) { _ in false } }
        #expect(throws: PairingError.tooManyAttempts) { try ledger.attempt(nonce: offer.nonce) { _ in false } }
        // Even a correct proof is refused afterwards.
        #expect(throws: PairingError.unknownOrUsedSecret) { try ledger.attempt(nonce: offer.nonce) { _ in true } }
    }

    @Test func ledgerGlobalRateLimit() throws {
        let clock = TestClock()
        let ledger = PairingSecretLedger(clock: clock.clock)
        for _ in 0..<10 { _ = try? ledger.attempt(nonce: Data(count: 16)) { _ in false } }
        let offer = try ledger.issue()
        #expect(throws: PairingError.rateLimited) { try ledger.attempt(nonce: offer.nonce) { _ in true } }
        clock.advance(3601)
        let fresh = try ledger.issue()
        try ledger.attempt(nonce: fresh.nonce) { _ in true }
    }

    @Test func ledgerCapsOutstandingOffersAndSecretsAreRandom() throws {
        let ledger = PairingSecretLedger(clock: TestClock().clock)
        let offers = try (0..<6).map { _ in try ledger.issue() }
        #expect(Set(offers.map(\.secret)).count == 6)
        #expect(throws: PairingError.unknownOrUsedSecret) { try ledger.attempt(nonce: offers[0].nonce) { _ in true } }
        try ledger.attempt(nonce: offers[5].nonce) { _ in true }
    }
}

@Suite struct SASTests {
    @Test func bothSidesComputeEqualCodes() throws {
        var a = SASExchange(), b = SASExchange()
        try a.receivePeerCommit(b.commit)
        try b.receivePeerCommit(a.commit)
        try a.receivePeerReveal(b.reveal)
        try b.receivePeerReveal(a.reveal)
        let transcript = Data(repeating: 7, count: 64)
        let ca = try a.code(transcript: transcript), cb = try b.code(transcript: transcript)
        #expect(ca == cb)
        #expect(ca.count == 6 && ca.allSatisfy(\.isNumber))
        // A different transcript (MITM with different identities) gives a different code (with overwhelming probability).
        var codes = Set<String>()
        for i in 0..<20 { codes.insert(try a.code(transcript: Data([UInt8(i)]))) }
        #expect(codes.count > 15)
    }

    @Test func commitMismatchRejected() throws {
        var a = SASExchange()
        let b = SASExchange(), mallory = SASExchange()
        try a.receivePeerCommit(b.commit)
        #expect(throws: PairingError.sasCommitMismatch) { try a.receivePeerReveal(mallory.reveal) }
        #expect(throws: PairingError.self) { try a.code(transcript: Data()) }
    }

    @Test func protocolOrderEnforced() throws {
        var a = SASExchange()
        let b = SASExchange()
        #expect(throws: PairingError.self) { try a.receivePeerReveal(b.reveal) }
        #expect(throws: PairingError.self) { try a.receivePeerCommit(Data(count: 31)) }
        try a.receivePeerCommit(b.commit)
        #expect(throws: PairingError.self) { try a.receivePeerCommit(b.commit) }
        #expect(throws: PairingError.sasCommitMismatch) { try a.receivePeerReveal(Data(count: 31)) }
    }

    @Test func lowOrderPeerKeyRejected() throws {
        var a = SASExchange()
        let zero = Data(count: 32)
        try a.receivePeerCommit(SASExchange.commit(forPublicKey: zero))
        try a.receivePeerReveal(zero)
        #expect(throws: PairingError.self) { try a.code(transcript: Data()) }
    }

    @Test func zeroPadding() {
        // The code formatter pads to six digits; exercise via many exchanges that at least one small value is well-formed.
        for _ in 0..<50 {
            var a = SASExchange(), b = SASExchange()
            try? a.receivePeerCommit(b.commit); try? a.receivePeerReveal(b.reveal)
            #expect((try? a.code(transcript: Data()))?.count == 6)
        }
    }
}

@Suite struct ResumeTokenTests {
    let id = Data(repeating: 1, count: 32)

    @Test func singleUse() throws {
        let store = ResumeTokenStore(clock: TestClock().clock)
        let t = try store.issue(for: id)
        #expect(t.count == 32)
        #expect(store.consume(t, identityHash: id))
        #expect(!store.consume(t, identityHash: id))
    }

    @Test func expiry() throws {
        let clock = TestClock()
        let store = ResumeTokenStore(clock: clock.clock)
        let t = try store.issue(for: id)
        clock.advance(601)
        #expect(!store.consume(t, identityHash: id))
        let t2 = try store.issue(for: id)
        clock.advance(599)
        #expect(store.consume(t2, identityHash: id))
    }

    @Test func identityBindingAndBurnOnMismatch() throws {
        let store = ResumeTokenStore(clock: TestClock().clock)
        let t = try store.issue(for: id)
        #expect(!store.consume(t, identityHash: Data(repeating: 2, count: 32)))
        #expect(!store.consume(t, identityHash: id))  // burned by the failed presentation
        #expect(!store.consume(Data(count: 31), identityHash: id))
        #expect(!store.consume(try LinkRandom.bytes(32), identityHash: id))
        #expect(throws: PairingError.self) { try store.issue(for: Data(count: 5)) }
    }
}
