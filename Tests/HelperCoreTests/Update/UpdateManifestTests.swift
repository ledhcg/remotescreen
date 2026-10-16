#if os(macOS)
import CryptoKit
import Foundation
import Testing
@testable import HelperCore

@Suite(.timeLimit(.minutes(2))) struct SemanticVersionTests {
    @Test func parsesAndOrders() throws {
        let v = { (s: String) throws -> SemanticVersion in try #require(SemanticVersion(s)) }
        #expect(try v("1.2.3") == SemanticVersion(major: 1, minor: 2, patch: 3))
        #expect(try v("0.9.0") < v("0.10.0"))
        #expect(try v("1.0.0-alpha") < v("1.0.0"))
        #expect(try v("1.0.0-alpha") < v("1.0.0-alpha.1"))
        #expect(try v("1.0.0-alpha.2") < v("1.0.0-alpha.10"))
        #expect(try v("1.0.0-1") < v("1.0.0-alpha"))
        #expect(try v("1.0.0-beta") < v("1.0.0-rc"))
        #expect(try v("1.0.0+build5") == v("1.0.0"))
        #expect(try v("2.0.0").description == "2.0.0")
    }

    @Test func rejectsGarbage() {
        for text in ["", "1", "1.2", "1.2.3.4", "01.2.3", "1.2.x", "-1.2.3", "1.2.3-", "1.2.3-a..b", "1.2.3 ", "9999999.0.0",
                     String(repeating: "1", count: 200)] {
            #expect(SemanticVersion(text) == nil, "\(text.prefix(20))")
        }
    }
}

@Suite(.timeLimit(.minutes(2))) struct UpdateVerifierTests {
    let key = Curve25519.Signing.PrivateKey()
    let current = SemanticVersion(major: 0, minor: 1, patch: 0)
    let macOS = SemanticVersion(major: 15, minor: 0, patch: 0)

    private func manifest(
        version: String = "0.2.0", url: String = "https://example.com/ScreonHelper-0.2.0.dmg",
        release: String = "https://example.com/releases/tag/helper-v0.2.0", minimumMacOS: String? = "15.0"
    ) -> Data {
        let sha = String(repeating: "ab", count: 32)
        var json = #"{"version":"\#(version)","url":"\#(url)","sha256":"\#(sha)","releaseURL":"\#(release)""#
        if let minimumMacOS { json += #","minimumMacOS":"\#(minimumMacOS)""# }
        return Data((json + "}").utf8)
    }

    private func sign(_ data: Data, with signer: Curve25519.Signing.PrivateKey? = nil) throws -> Data {
        Data(try (signer ?? key).signature(for: data).base64EncodedString().utf8)
    }

    @Test func acceptsASignedManifest() throws {
        let data = manifest()
        let verified = try UpdateVerifier.verify(manifest: data, signature: try sign(data), publicKey: key.publicKey)
        #expect(verified.version == SemanticVersion("0.2.0"))
        #expect(verified.minimumMacOS == SemanticVersion("15.0.0"))
        #expect(verified.downloadURL.host == "example.com")
        #expect(UpdateChecker.decide(verified, current: current, macOS: macOS) == .available(verified))
    }

    @Test func rejectsABadOrForeignSignature() throws {
        let data = manifest()
        let other = Curve25519.Signing.PrivateKey()
        #expect(throws: UpdateError.badSignature) { try UpdateVerifier.verify(manifest: data, signature: try sign(data, with: other), publicKey: key.publicKey) }
        #expect(throws: UpdateError.badSignature) { try UpdateVerifier.verify(manifest: data, signature: Data("AAAA".utf8), publicKey: key.publicKey) }
        #expect(throws: UpdateError.badSignature) { try UpdateVerifier.verify(manifest: data, signature: Data(), publicKey: key.publicKey) }
        #expect(throws: UpdateError.badSignature) { try UpdateVerifier.verify(manifest: data, signature: Data([0xff, 0xfe]), publicKey: key.publicKey) }
    }

    @Test func aTamperedManifestFailsTheSignature() throws {
        let data = manifest()
        let signature = try sign(data)
        let tampered = manifest(version: "9.9.9")
        #expect(throws: UpdateError.badSignature) { try UpdateVerifier.verify(manifest: tampered, signature: signature, publicKey: key.publicKey) }
    }

    @Test func refusesOversizedInput() throws {
        let big = Data(repeating: 0x20, count: UpdateVerifier.maxManifestBytes + 1)
        #expect(throws: UpdateError.tooLarge) { try UpdateVerifier.verify(manifest: big, signature: try sign(big), publicKey: key.publicKey) }
        let data = manifest()
        let hugeSignature = Data(repeating: 0x41, count: UpdateVerifier.maxSignatureBytes + 1)
        #expect(throws: UpdateError.tooLarge) { try UpdateVerifier.verify(manifest: data, signature: hugeSignature, publicKey: key.publicKey) }
    }

    @Test func refusesNonHTTPSAndOddURLs() throws {
        for bad in ["http://example.com/a.dmg", "file:///etc/passwd", "ftp://example.com/a", "javascript:alert(1)",
                    "https://user:pw@example.com/a.dmg", "https:///nohost", "not a url", ""] {
            let data = manifest(url: bad)
            #expect(throws: UpdateError.self, "\(bad)") { try UpdateVerifier.verify(manifest: data, signature: try sign(data), publicKey: key.publicKey) }
            let data2 = manifest(release: bad)
            #expect(throws: UpdateError.self, "\(bad)") { try UpdateVerifier.verify(manifest: data2, signature: try sign(data2), publicKey: key.publicKey) }
        }
    }

    @Test func refusesMalformedFieldsEvenWhenSigned() throws {
        let bodies = [
            "{}", "[]", "null", #"{"version":"x"}"#,
            #"{"version":"1.0","url":"https://e.com/a","sha256":"ab","releaseURL":"https://e.com/r"}"#,
            #"{"version":"1.0.0","url":"https://e.com/a","sha256":"zz\#(String(repeating: "a", count: 62))","releaseURL":"https://e.com/r"}"#,
            #"{"version":"1.0.0","url":"https://e.com/a","sha256":"\#(String(repeating: "a", count: 64))","releaseURL":"https://e.com/r","minimumMacOS":"soon"}"#,
        ]
        for body in bodies {
            let data = Data(body.utf8)
            #expect(throws: UpdateError.self, "\(body.prefix(40))") { try UpdateVerifier.verify(manifest: data, signature: try sign(data), publicKey: key.publicKey) }
        }
    }

    @Test func downgradeAndSameVersionAreNotUpdates() throws {
        for version in ["0.1.0", "0.0.9", "0.1.0-rc.1"] {
            let data = manifest(version: version)
            let verified = try UpdateVerifier.verify(manifest: data, signature: try sign(data), publicKey: key.publicKey)
            #expect(UpdateChecker.decide(verified, current: current, macOS: macOS) == .upToDate, "\(version)")
        }
    }

    @Test func aNewerVersionNeedingANewerMacOSIsReportedAsSuch() throws {
        let data = manifest(minimumMacOS: "26.0")
        let verified = try UpdateVerifier.verify(manifest: data, signature: try sign(data), publicKey: key.publicKey)
        #expect(UpdateChecker.decide(verified, current: current, macOS: macOS) == .requiresNewerMacOS(verified))
    }

    @Test func publicKeyParsing() throws {
        let good = key.publicKey.rawRepresentation.base64EncodedString()
        _ = try UpdateVerifier.publicKey(base64: " \(good)\n")
        for bad in ["", "REPLACE_WITH_BASE64_ED25519_PUBLIC_KEY", Data(repeating: 1, count: 31).base64EncodedString()] {
            #expect(throws: UpdateError.notConfigured) { try UpdateVerifier.publicKey(base64: bad) }
        }
    }
}

@Suite(.timeLimit(.minutes(2))) struct UpdateCheckerTests {
    let key = Curve25519.Signing.PrivateKey()
    let manifestURL = URL(string: "https://example.com/releases/latest/download/update-manifest.json")!

    private func checker(manifest: Data, signatureFor: Data? = nil, fetched: (@Sendable (URL) -> Void)? = nil) throws -> UpdateChecker {
        let signature = Data(try key.signature(for: signatureFor ?? manifest).base64EncodedString().utf8)
        return UpdateChecker(manifestURL: manifestURL, publicKeyBase64: key.publicKey.rawRepresentation.base64EncodedString()) { url, _ in
            fetched?(url)
            return url.path.hasSuffix(".sig") ? signature : manifest
        }
    }

    private let body = Data(#"{"version":"1.0.0","url":"https://e.com/a.dmg","sha256":"\#(String(repeating: "c", count: 64))","releaseURL":"https://e.com/r"}"#.utf8)

    @Test func signatureLivesNextToTheManifest() throws {
        let c = try checker(manifest: body)
        #expect(c.signatureURL?.absoluteString == "https://example.com/releases/latest/download/update-manifest.json.sig")
    }

    @Test func endToEnd() async throws {
        let decision = try await checker(manifest: body).check(current: SemanticVersion(major: 0, minor: 1, patch: 0), macOS: SemanticVersion(major: 15, minor: 0, patch: 0))
        guard case .available(let manifest) = decision else { Issue.record("expected an update"); return }
        #expect(manifest.version == SemanticVersion("1.0.0"))
    }

    @Test func aBadSignatureThrows() async throws {
        let c = try checker(manifest: body, signatureFor: Data("something else".utf8))
        await #expect(throws: UpdateError.badSignature) {
            try await c.check(current: SemanticVersion(major: 0, minor: 1, patch: 0), macOS: SemanticVersion(major: 15, minor: 0, patch: 0))
        }
    }

    @Test func thePlaceholderKeyNeverReachesTheNetwork() async {
        let c = UpdateChecker(manifestURL: manifestURL, publicKeyBase64: "REPLACE_WITH_BASE64_ED25519_PUBLIC_KEY") { _, _ in
            Issue.record("fetched with no key configured")
            return Data()
        }
        await #expect(throws: UpdateError.notConfigured) {
            try await c.check(current: SemanticVersion(major: 0, minor: 1, patch: 0), macOS: SemanticVersion(major: 15, minor: 0, patch: 0))
        }
    }

    @Test func anHTTPManifestURLIsRefusedBeforeFetching() async {
        let c = UpdateChecker(
            manifestURL: URL(string: "http://example.com/update-manifest.json")!,
            publicKeyBase64: key.publicKey.rawRepresentation.base64EncodedString()
        ) { _, _ in
            Issue.record("fetched an insecure URL")
            return Data()
        }
        await #expect(throws: UpdateError.insecureURL) {
            try await c.check(current: SemanticVersion(major: 0, minor: 1, patch: 0), macOS: SemanticVersion(major: 15, minor: 0, patch: 0))
        }
    }

    @Test func theFetcherRefusesNonHTTPS() async {
        await #expect(throws: UpdateError.insecureURL) { try await HTTPSFetcher.fetch(URL(string: "http://example.com/x")!, maxBytes: 10) }
        await #expect(throws: UpdateError.insecureURL) { try await HTTPSFetcher.fetch(URL(string: "file:///etc/hosts")!, maxBytes: 10) }
    }
}
#endif
