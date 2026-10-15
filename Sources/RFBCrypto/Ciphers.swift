import CommonCrypto
import CryptoKit
import Foundation
import Security

public enum RFBCryptoError: Error, Equatable, Sendable {
    case invalidLength(String)
    case cipherFailure(Int32)
    case randomFailure(Int32)
}

/// Cryptographic random numbers from the operating system.
public enum SecureRandom {
    public static func bytes(_ count: Int) throws -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &buffer)
        guard status == errSecSuccess else { throw RFBCryptoError.randomFailure(status) }
        return buffer
    }
}

public enum MD5 {
    /// MD5 is used only because Apple's ARD protocol mandates it, not for any new security purpose.
    public static func hash(_ data: Data) -> Data {
        Data(Insecure.MD5.hash(data: data))
    }
}

/// AES-128 in ECB mode without padding. The input must be a multiple of 16 bytes.
public enum AES128ECB {
    public static func encrypt(_ data: Data, key: Data) throws -> Data {
        try crypt(CCOperation(kCCEncrypt), data, key: key)
    }

    public static func decrypt(_ data: Data, key: Data) throws -> Data {
        try crypt(CCOperation(kCCDecrypt), data, key: key)
    }

    private static func crypt(_ operation: CCOperation, _ data: Data, key: Data) throws -> Data {
        guard key.count == kCCKeySizeAES128 else { throw RFBCryptoError.invalidLength("AES-128 key must be 16 bytes") }
        guard data.count.isMultiple(of: kCCBlockSizeAES128) else {
            throw RFBCryptoError.invalidLength("AES-ECB data must be a multiple of 16 bytes")
        }
        return try ecb(operation, algorithm: CCAlgorithm(kCCAlgorithmAES), blockSize: kCCBlockSizeAES128, data, key: key)
    }
}

/// DES-ECB, used only for VNC authentication (RFB type 2). DES is weak; the protocol mandates it.
public enum DESECB {
    public static func encrypt(_ data: Data, key: Data) throws -> Data {
        guard key.count == kCCKeySizeDES else { throw RFBCryptoError.invalidLength("DES key must be 8 bytes") }
        guard data.count.isMultiple(of: kCCBlockSizeDES) else {
            throw RFBCryptoError.invalidLength("DES-ECB data must be a multiple of 8 bytes")
        }
        return try ecb(CCOperation(kCCEncrypt), algorithm: CCAlgorithm(kCCAlgorithmDES), blockSize: kCCBlockSizeDES, data, key: key)
    }
}

/// VNC authentication (RFB security type 2): encrypts the 16-byte challenge with DES using a key derived from the password.
public enum VNCAuthentication {
    /// The VNC DES key: takes at most the first 8 bytes of the password, pads with zeros, then **reverses the bit order**
    /// within each byte (a historical quirk of VNC).
    public static func key(forPassword password: String) -> Data {
        var bytes = Array(password.utf8.prefix(8))
        bytes.append(contentsOf: repeatElement(0, count: 8 - bytes.count))
        return Data(bytes.map(reverseBits))
    }

    /// Answers the server's 16-byte challenge: DES-ECB over two 8-byte blocks.
    public static func response(to challenge: Data, password: String) throws -> Data {
        guard challenge.count == 16 else { throw RFBCryptoError.invalidLength("VNC challenge must be 16 bytes") }
        return try DESECB.encrypt(challenge, key: key(forPassword: password))
    }

    private static func reverseBits(_ byte: UInt8) -> UInt8 {
        var input = byte
        var output: UInt8 = 0
        for _ in 0..<8 {
            output = (output << 1) | (input & 1)
            input >>= 1
        }
        return output
    }
}

private func ecb(
    _ operation: CCOperation,
    algorithm: CCAlgorithm,
    blockSize: Int,
    _ data: Data,
    key: Data
) throws -> Data {
    if data.isEmpty { return Data() }
    var output = Data(count: data.count + blockSize)
    var moved = 0
    let capacity = output.count
    let status = output.withUnsafeMutableBytes { outPointer in
        data.withUnsafeBytes { inPointer in
            key.withUnsafeBytes { keyPointer in
                CCCrypt(
                    operation, algorithm, CCOptions(kCCOptionECBMode),
                    keyPointer.baseAddress, key.count,
                    nil,
                    inPointer.baseAddress, data.count,
                    outPointer.baseAddress, capacity,
                    &moved
                )
            }
        }
    }
    guard status == kCCSuccess else { throw RFBCryptoError.cipherFailure(Int32(status)) }
    output.removeSubrange(moved...)
    return output
}
