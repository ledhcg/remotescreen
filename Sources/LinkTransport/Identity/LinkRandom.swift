import Foundation
import Security

public enum LinkRandomError: Error, Equatable { case failed(Int32) }

/// Cryptographic randomness from `SecRandomCopyBytes`.
public enum LinkRandom {
    public static func bytes(_ count: Int) throws -> Data {
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes { buf -> Int32 in
            guard let base = buf.baseAddress else { return errSecSuccess }
            return SecRandomCopyBytes(kSecRandomDefault, count, base)
        }
        guard status == errSecSuccess else { throw LinkRandomError.failed(status) }
        return data
    }
}

/// Constant-time comparison of two byte strings (length is not secret).
public func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
    guard a.count == b.count else { return false }
    var diff: UInt8 = 0
    for (x, y) in zip(a, b) { diff |= x ^ y }
    return diff == 0
}
