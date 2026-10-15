import RFBCrypto

/// Nhóm Diffie-Hellman đã biết là an toàn, để không phải kiểm tra tính nguyên tố (một phép lũy thừa 4096-bit mất khoảng
/// 0,3 giây mỗi vòng) ở mỗi lần đăng nhập vào Mac.
///
/// Số nguyên tố này là nhóm MODP 4096-bit của RFC 3526 và là nhóm `screensharingd` (macOS 27) gửi thật. Đã kiểm tra độc lập
/// (Miller-Rabin 20 vòng) rằng cả p lẫn (p-1)/2 đều là số nguyên tố, tức p là safe prime.
enum KnownDHGroups {
    static let modp4096: BigUInt = BigUInt(bigEndianBytes: hexBytes([
        "ffffffffffffffffc90fdaa22168c234c4c6628b80dc1cd129024e088a67cc74",
        "020bbea63b139b22514a08798e3404ddef9519b3cd3a431b302b0a6df25f1437",
        "4fe1356d6d51c245e485b576625e7ec6f44c42e9a637ed6b0bff5cb6f406b7ed",
        "ee386bfb5a899fa5ae9f24117c4b1fe649286651ece45b3dc2007cb8a163bf05",
        "98da48361c55d39a69163fa8fd24cf5f83655d23dca3ad961c62f356208552bb",
        "9ed529077096966d670c354e4abc9804f1746c08ca18217c32905e462e36ce3b",
        "e39e772c180e86039b2783a2ec07a28fb5c55df06f4c52c9de2bcbf695581718",
        "3995497cea956ae515d2261898fa051015728e5a8aaac42dad33170d04507a33",
        "a85521abdf1cba64ecfb850458dbef0a8aea71575d060c7db3970f85a6e1e4c7",
        "abf5ae8cdb0933d71e8c94e04a25619dcee3d2261ad2ee6bf12ffa06d98a0864",
        "d87602733ec86a64521f2b18177b200cbbe117577a615d6c770988c0bad946e2",
        "08e24fa074e5ab3143db5bfce0fd108e4b82d120a92108011a723c12a787e6d7",
        "88719a10bdba5b2699c327186af4e23c1a946834b6150bda2583e9ca2ad44ce8",
        "dbbbc2db04de8ef92e8efc141fbecaa6287c59474e6bc05d99b2964fa090c3a2",
        "233ba186515be7ed1f612970cee2d7afb81bdd762170481cd0069127d5b05aa9",
        "93b4ea988d8fddc186ffb7dc90a6c08f4df435c934063199ffffffffffffffff"
    ].joined()))

    private static func hexBytes(_ text: String) -> [UInt8] {
        var bytes: [UInt8] = []
        var high: UInt8?
        for character in text.utf8 {
            let nibble: UInt8 = character <= 57 ? character - 48 : character - 87
            if let h = high { bytes.append(h << 4 | nibble); high = nil } else { high = nibble }
        }
        return bytes
    }
}
