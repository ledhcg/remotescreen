import CryptoKit
import Foundation

/// The channel binding mixed into the pairing transcript (plan §6.2 step 3).
public enum PairingBinding: Sendable, Equatable {
    /// 32 bytes from the TLS exporter `EXPORTER-screon-pair`.
    case exporter(Data)
    /// Fallback when the transport has no exporter: the QR nonce and a fresh 32-byte challenge the helper sent.
    case helperChallenge(nonce: Data, challenge: Data)
}

/// `pair.prove` MAC.
///
/// - key = HKDF-SHA256(ikm: secret, salt: nonce, info: "screon pair v1", 32 bytes)
/// - mac = HMAC-SHA256(key, transcript)
///
/// Transcript encoding: one mode byte, then fields, each `u32 big-endian length ‖ bytes`.
///
///     exporter mode   (0x01): field(exporter[32]) field(macSPKIHash[32]) field(ipadSPKIHash[32]) field(deviceNameUTF8)
///     challenge mode  (0x02): field(macSPKIHash[32]) field(ipadSPKIHash[32]) field(deviceNameUTF8)
///                             field(nonce[16]) field(challenge[32])
///
/// Length prefixes remove field-boundary ambiguity; the mode byte keeps the two variants from colliding.
public enum PairingProof {
    public static let info = Data("screon pair v1".utf8)
    public static let maxDeviceNameBytes = 64

    public static func key(secret: Data, nonce: Data) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: secret), salt: nonce, info: info, outputByteCount: 32)
    }

    static func field(_ d: Data) -> Data {
        var n = UInt32(d.count).bigEndian
        return Data(bytes: &n, count: 4) + d
    }

    public static func transcript(
        binding: PairingBinding, macSPKIHash: Data, ipadSPKIHash: Data, deviceName: String
    ) throws -> Data {
        let name = Data(deviceName.utf8)
        guard macSPKIHash.count == 32, ipadSPKIHash.count == 32, !name.isEmpty, name.count <= maxDeviceNameBytes else {
            throw PairingError.invalidInput("transcript fields")
        }
        switch binding {
        case .exporter(let ex):
            guard ex.count == 32 else { throw PairingError.invalidInput("exporter") }
            return Data([0x01]) + field(ex) + field(macSPKIHash) + field(ipadSPKIHash) + field(name)
        case .helperChallenge(let nonce, let challenge):
            guard nonce.count == 16, challenge.count == 32 else { throw PairingError.invalidInput("challenge") }
            return Data([0x02]) + field(macSPKIHash) + field(ipadSPKIHash) + field(name) + field(nonce) + field(challenge)
        }
    }

    public static func mac(
        secret: Data, nonce: Data, binding: PairingBinding, macSPKIHash: Data, ipadSPKIHash: Data, deviceName: String
    ) throws -> Data {
        guard secret.count == 16, nonce.count == 16 else { throw PairingError.invalidInput("secret/nonce") }
        let t = try transcript(binding: binding, macSPKIHash: macSPKIHash, ipadSPKIHash: ipadSPKIHash, deviceName: deviceName)
        return Data(HMAC<SHA256>.authenticationCode(for: t, using: key(secret: secret, nonce: nonce)))
    }

    /// Constant-time verification. Malformed inputs verify as `false`.
    public static func verify(
        mac received: Data, secret: Data, nonce: Data, binding: PairingBinding,
        macSPKIHash: Data, ipadSPKIHash: Data, deviceName: String
    ) -> Bool {
        guard received.count == 32,
              let t = try? transcript(binding: binding, macSPKIHash: macSPKIHash, ipadSPKIHash: ipadSPKIHash, deviceName: deviceName),
              secret.count == 16, nonce.count == 16
        else { return false }
        return HMAC<SHA256>.isValidAuthenticationCode(received, authenticating: t, using: key(secret: secret, nonce: nonce))
    }
}
