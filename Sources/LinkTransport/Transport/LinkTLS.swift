import Foundation
import Network
import Security

/// What the TLS handshake established about the peer.
public struct LinkPeerInfo: Sendable, Equatable {
    /// SHA-256 of the peer certificate's SubjectPublicKeyInfo.
    public let spkiHash: Data
    /// 32 bytes from the TLS exporter `EXPORTER-screon-pair`, identical on both ends of one connection. `nil` if the
    /// transport cannot provide it (pairing then falls back to the helper-challenge transcript).
    public let exporter: Data?
}

/// A `SecIdentity` that can cross concurrency domains. Security.framework identities are immutable references.
public struct LinkSecIdentity: @unchecked Sendable {
    public let identity: SecIdentity
    public init(_ identity: SecIdentity) { self.identity = identity }
}

extension LinkSecIdentity {
    /// The identity's certificate.
    public func certificate() throws -> LinkCertificate {
        var cert: SecCertificate?
        let status = SecIdentityCopyCertificate(identity, &cert)
        guard status == errSecSuccess, let cert else { throw LinkIdentityError.keychain(status) }
        return try LinkCertificate(der: SecCertificateCopyData(cert) as Data)
    }
}

/// Records why the verify block rejected a peer, so the caller can report `pinMismatch` instead of a generic TLS error.
final class PeerVerifyRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var failure: PinError?
    private var onFailure: (@Sendable () -> Void)?
    /// Called when the verify block rejects a peer, so a waiting `start` can stop at once instead of timing out.
    func setOnFailure(_ f: @escaping @Sendable () -> Void) { lock.withLock { onFailure = f } }
    func record(_ error: PinError) {
        let callback = lock.withLock { () -> (@Sendable () -> Void)? in failure = error; return onFailure }
        callback?()
    }
    var lastFailure: PinError? { lock.withLock { failure } }
}

enum LinkTLS {
    static let exporterLabel = "EXPORTER-screon-pair"
    static let exporterLength = 32

    /// Applies identity, TLS 1.3 and the pin verifier to `sec`. Both sides require the peer's certificate (mutual TLS).
    /// - `policy`: `.pinned` on a client that knows the helper (and on a QR pairing client); `.pairing` otherwise. The
    ///   server always uses `.pairing`: it learns the client's hash from the handshake and decides authorisation in the
    ///   session layer, so an unknown client can reach the pairing state machine and nothing else.
    static func configure(
        _ sec: sec_protocol_options_t, identity: LinkSecIdentity, policy: PinPolicy,
        recorder: PeerVerifyRecorder, queue: DispatchQueue
    ) {
        sec_protocol_options_set_min_tls_protocol_version(sec, .TLSv13)
        sec_protocol_options_set_max_tls_protocol_version(sec, .TLSv13)
        if let local = sec_identity_create(identity.identity) {
            sec_protocol_options_set_local_identity(sec, local)
        }
        sec_protocol_options_set_peer_authentication_required(sec, true)
        sec_protocol_options_set_verify_block(sec, { _, secTrust, complete in
            let trust = sec_trust_copy_ref(secTrust).takeRetainedValue()
            do {
                _ = try PinVerifier.evaluate(trust: trust, policy: policy)
                complete(true)
            } catch let error as PinError {
                recorder.record(error)
                complete(false)
            } catch {
                complete(false)
            }
        }, queue)
    }

    /// Peer hash and exporter from handshake metadata.
    static func peerInfo(from metadata: sec_protocol_metadata_t) -> LinkPeerInfo? {
        var leaf: Data?
        _ = sec_protocol_metadata_access_peer_certificate_chain(metadata) { cert in
            guard leaf == nil else { return }
            leaf = SecCertificateCopyData(sec_certificate_copy_ref(cert).takeRetainedValue()) as Data
        }
        guard let leaf, let cert = try? LinkCertificate(der: leaf) else { return nil }
        var exporter: Data?
        let label = exporterLabel
        if let secret = label.withCString({ sec_protocol_metadata_create_secret(metadata, label.utf8.count, $0, exporterLength) }) {
            let data = (secret as AnyObject as? Data) ?? Data(secret as DispatchData)
            if data.count == exporterLength { exporter = data }
        }
        return LinkPeerInfo(spkiHash: cert.spkiHash, exporter: exporter)
    }
}
