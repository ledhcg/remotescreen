import CommonCrypto
import CryptoKit
import Foundation
import Security

public enum RFBCryptoError: Error, Equatable, Sendable {
    case invalidLength(String)
    case cipherFailure(Int32)
    case randomFailure(Int32)
}

/// Số ngẫu nhiên mật mã từ hệ điều hành.
public enum SecureRandom {
    public static func bytes(_ count: Int) throws -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &buffer)
        guard status == errSecSuccess else { throw RFBCryptoError.randomFailure(status) }
        return buffer
    }
}

public enum MD5 {
    /// MD5 chỉ dùng vì giao thức ARD của Apple quy định, không dùng cho mục đích bảo mật mới.
    public static func hash(_ data: Data) -> Data {
        Data(Insecure.MD5.hash(data: data))
    }
}

/// AES-128 chế độ ECB không đệm. Đầu vào phải là bội số của 16 byte.
public enum AES128ECB {
    public static func encrypt(_ data: Data, key: Data) throws -> Data {
        try crypt(CCOperation(kCCEncrypt), data, key: key)
    }

    public static func decrypt(_ data: Data, key: Data) throws -> Data {
        try crypt(CCOperation(kCCDecrypt), data, key: key)
    }

    private static func crypt(_ operation: CCOperation, _ data: Data, key: Data) throws -> Data {
        guard key.count == kCCKeySizeAES128 else { throw RFBCryptoError.invalidLength("khóa AES-128 phải 16 byte") }
        guard data.count.isMultiple(of: kCCBlockSizeAES128) else {
            throw RFBCryptoError.invalidLength("dữ liệu AES-ECB phải là bội số của 16 byte")
        }
        return try ecb(operation, algorithm: CCAlgorithm(kCCAlgorithmAES), blockSize: kCCBlockSizeAES128, data, key: key)
    }
}

/// DES-ECB, chỉ phục vụ xác thực VNC (RFB type 2). DES đã yếu, giao thức này quy định.
public enum DESECB {
    public static func encrypt(_ data: Data, key: Data) throws -> Data {
        guard key.count == kCCKeySizeDES else { throw RFBCryptoError.invalidLength("khóa DES phải 8 byte") }
        guard data.count.isMultiple(of: kCCBlockSizeDES) else {
            throw RFBCryptoError.invalidLength("dữ liệu DES-ECB phải là bội số của 8 byte")
        }
        return try ecb(CCOperation(kCCEncrypt), algorithm: CCAlgorithm(kCCAlgorithmDES), blockSize: kCCBlockSizeDES, data, key: key)
    }
}

/// Xác thực VNC (RFB security type 2): mã hóa thử thách 16 byte bằng DES với khóa suy từ mật khẩu.
public enum VNCAuthentication {
    /// Khóa DES của VNC: lấy tối đa 8 byte đầu của mật khẩu, đệm số 0, rồi **đảo thứ tự bit**
    /// trong từng byte (một đặc thù lịch sử của VNC).
    public static func key(forPassword password: String) -> Data {
        var bytes = Array(password.utf8.prefix(8))
        bytes.append(contentsOf: repeatElement(0, count: 8 - bytes.count))
        return Data(bytes.map(reverseBits))
    }

    /// Trả lời thử thách 16 byte của server: DES-ECB hai khối 8 byte.
    public static func response(to challenge: Data, password: String) throws -> Data {
        guard challenge.count == 16 else { throw RFBCryptoError.invalidLength("thử thách VNC phải 16 byte") }
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
