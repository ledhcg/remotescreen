#if os(macOS)
import CryptoKit
import Foundation

// Update check for the helper (plan M4 A6): fetch a small JSON manifest and a detached Ed25519 signature over its exact bytes,
// verify the signature with the key embedded in the app, then compare versions. Nothing is downloaded or installed here; the
// person is pointed at the release page. The manifest is hostile input until the signature has been verified.
//
// Manifest (`update-manifest.json`) written by the release workflow and signed by `scripts/sign-update-manifest.swift`:
//
//     { "version": "0.2.0", "url": "https://…/ScreonHelper-0.2.0.dmg", "sha256": "<64 hex>",
//       "releaseURL": "https://…/releases/tag/…", "minimumMacOS": "15.0" }
//
// The signature file is `<manifest URL>.sig`: base64 of the 64-byte Ed25519 signature of the manifest bytes.

public enum UpdateError: Error, Equatable {
    /// No usable public key is embedded (the placeholder value is still in place).
    case notConfigured
    case insecureURL
    case tooLarge
    case badSignature
    case malformed(String)
    case network(String)
}

/// `MAJOR.MINOR.PATCH` with an optional `-prerelease` suffix. Build metadata (`+…`) is ignored, as in semver 2.0.
public struct SemanticVersion: Sendable, Equatable, Comparable, CustomStringConvertible {
    public static let maxLength = 64
    public var major: Int
    public var minor: Int
    public var patch: Int
    public var prerelease: [String]

    public init(major: Int, minor: Int, patch: Int, prerelease: [String] = []) {
        self.major = major; self.minor = minor; self.patch = patch; self.prerelease = prerelease
    }

    public init?(_ text: String) {
        guard text.utf8.count <= Self.maxLength else { return nil }
        var core = Substring(text)
        if let plus = core.firstIndex(of: "+") { core = core[..<plus] }
        var pre: [String] = []
        if let dash = core.firstIndex(of: "-") {
            let tail = core[core.index(after: dash)...]
            core = core[..<dash]
            pre = tail.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            guard !pre.isEmpty, pre.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") } }) else { return nil }
        }
        let parts = core.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.count <= 6, part.allSatisfy({ $0.isASCII && $0.isNumber }), part == "0" || part.first != "0",
                  let value = Int(part)
            else { return nil }
            numbers.append(value)
        }
        self.init(major: numbers[0], minor: numbers[1], patch: numbers[2], prerelease: pre)
    }

    public var description: String {
        let core = "\(major).\(minor).\(patch)"
        return prerelease.isEmpty ? core : core + "-" + prerelease.joined(separator: ".")
    }

    public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }
        if lhs.prerelease.isEmpty || rhs.prerelease.isEmpty { return !lhs.prerelease.isEmpty && rhs.prerelease.isEmpty }
        for (a, b) in zip(lhs.prerelease, rhs.prerelease) where a != b {
            switch (Int(a), Int(b)) {
            case (let x?, let y?): return x < y
            case (_?, nil): return true  // numeric identifiers sort before alphanumeric ones
            case (nil, _?): return false
            default: return a < b
            }
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }
}

/// A verified manifest. Only `UpdateVerifier.verify` creates one from bytes.
public struct UpdateManifest: Sendable, Equatable {
    public var version: SemanticVersion
    public var downloadURL: URL
    public var sha256: String
    public var releaseURL: URL
    public var minimumMacOS: SemanticVersion?
}

public enum UpdateVerifier {
    public static let maxManifestBytes = 16 * 1024
    public static let maxSignatureBytes = 512

    private struct Wire: Decodable {
        var version: String
        var url: String
        var sha256: String
        var releaseURL: String
        var minimumMacOS: String?
    }

    /// Parses a base64 raw Ed25519 public key (32 bytes). Anything else, including the placeholder, is `notConfigured`.
    public static func publicKey(base64 text: String) throws -> Curve25519.Signing.PublicKey {
        guard let data = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)), data.count == 32,
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: data)
        else { throw UpdateError.notConfigured }
        return key
    }

    /// Verifies the signature over the exact manifest bytes first, and only then parses the JSON.
    public static func verify(manifest: Data, signature: Data, publicKey: Curve25519.Signing.PublicKey) throws -> UpdateManifest {
        guard manifest.count <= maxManifestBytes, signature.count <= maxSignatureBytes else { throw UpdateError.tooLarge }
        guard let text = String(data: signature, encoding: .utf8),
              let raw = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)), raw.count == 64,
              publicKey.isValidSignature(raw, for: manifest)
        else { throw UpdateError.badSignature }

        guard let wire = try? JSONDecoder().decode(Wire.self, from: manifest) else { throw UpdateError.malformed("json") }
        guard let version = SemanticVersion(wire.version) else { throw UpdateError.malformed("version") }
        let minimum: SemanticVersion?
        if let text = wire.minimumMacOS {
            guard let parsed = SemanticVersion(text) ?? SemanticVersion(text + ".0") else { throw UpdateError.malformed("minimumMacOS") }
            minimum = parsed
        } else {
            minimum = nil
        }
        let hex = wire.sha256.lowercased()
        guard hex.utf8.count == 64, hex.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { throw UpdateError.malformed("sha256") }
        return UpdateManifest(
            version: version, downloadURL: try httpsURL(wire.url), sha256: hex, releaseURL: try httpsURL(wire.releaseURL),
            minimumMacOS: minimum)
    }

    /// `https` with a host and no embedded credentials.
    static func httpsURL(_ text: String) throws -> URL {
        guard text.utf8.count <= 2048, let url = URL(string: text), url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil
        else { throw UpdateError.insecureURL }
        return url
    }
}

public enum UpdateDecision: Sendable, Equatable {
    case upToDate
    case available(UpdateManifest)
    /// A newer version exists but needs a newer macOS than this Mac runs.
    case requiresNewerMacOS(UpdateManifest)
}

public struct UpdateChecker: Sendable {
    /// Returns at most `maxBytes` bytes of the body of an HTTPS URL, or throws.
    public typealias Fetch = @Sendable (URL, Int) async throws -> Data

    public var manifestURL: URL
    public var publicKeyBase64: String
    public var fetch: Fetch

    public init(manifestURL: URL, publicKeyBase64: String, fetch: @escaping Fetch) {
        self.manifestURL = manifestURL; self.publicKeyBase64 = publicKeyBase64; self.fetch = fetch
    }

    /// `<manifest URL>.sig`
    public var signatureURL: URL? {
        guard var parts = URLComponents(url: manifestURL, resolvingAgainstBaseURL: false) else { return nil }
        parts.path += ".sig"
        return parts.url
    }

    /// A manifest that is not newer than `current` (a replayed old one, or a downgrade) never produces an update.
    public static func decide(_ manifest: UpdateManifest, current: SemanticVersion, macOS: SemanticVersion) -> UpdateDecision {
        guard manifest.version > current else { return .upToDate }
        if let minimum = manifest.minimumMacOS, minimum > macOS { return .requiresNewerMacOS(manifest) }
        return .available(manifest)
    }

    public func check(current: SemanticVersion, macOS: SemanticVersion) async throws -> UpdateDecision {
        let key = try UpdateVerifier.publicKey(base64: publicKeyBase64)
        guard manifestURL.scheme?.lowercased() == "https", let signatureURL else { throw UpdateError.insecureURL }
        let manifest = try await fetch(manifestURL, UpdateVerifier.maxManifestBytes)
        let signature = try await fetch(signatureURL, UpdateVerifier.maxSignatureBytes)
        let verified = try UpdateVerifier.verify(manifest: manifest, signature: signature, publicKey: key)
        return Self.decide(verified, current: current, macOS: macOS)
    }
}

/// HTTPS-only download with a hard size cap, no cookies and no cache. A redirect to anything but HTTPS is refused.
public enum HTTPSFetcher {
    private final class RedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(
            _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
        ) {
            completionHandler(request.url?.scheme?.lowercased() == "https" ? request : nil)
        }
    }

    public static func fetch(_ url: URL, maxBytes: Int) async throws -> Data {
        guard url.scheme?.lowercased() == "https" else { throw UpdateError.insecureURL }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration, delegate: RedirectGuard(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        do {
            let (bytes, response) = try await session.bytes(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw UpdateError.network("status") }
            if http.expectedContentLength > Int64(maxBytes) { throw UpdateError.tooLarge }
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
                if data.count > maxBytes { throw UpdateError.tooLarge }
            }
            return data
        } catch let error as UpdateError {
            throw error
        } catch {
            throw UpdateError.network((error as NSError).domain + ":" + String((error as NSError).code))
        }
    }
}
#endif
