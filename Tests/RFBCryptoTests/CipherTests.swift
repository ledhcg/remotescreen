import Foundation
import Testing
@testable import RFBCrypto

@Suite("VNC authentication")
struct VNCAuthenticationTests {
    @Test(arguments: vncVectors.indices)
    func responseMatchesOpenSSL(index: Int) throws {
        let vector = vncVectors[index]
        let response = try VNCAuthentication.response(to: Data(hex: vector.challenge), password: vector.password)
        #expect(response.hex == vector.response, "mật khẩu \"\(vector.password)\"")
    }

    @Test func keyReversesBitsAndPads() {
        // 'A' = 0b01000001 → đảo bit = 0b10000010 = 0x82
        #expect(VNCAuthentication.key(forPassword: "A").hex == "8200000000000000")
        // 8 byte đầu mới được dùng
        #expect(VNCAuthentication.key(forPassword: "12345678XYZ") == VNCAuthentication.key(forPassword: "12345678"))
    }

    @Test func rejectsWrongChallengeLength() {
        #expect(throws: RFBCryptoError.self) { try VNCAuthentication.response(to: Data(count: 15), password: "x") }
    }

    @Test func desMatchesClassicFIPSExample() throws {
        // Ví dụ DES kinh điển: khóa 133457799BBCDFF1, bản rõ 0123456789ABCDEF → 85E813540F0AB405.
        let out = try DESECB.encrypt(Data(hex: "0123456789abcdef"), key: Data(hex: "133457799bbcdff1"))
        #expect(out.hex == "85e813540f0ab405")
    }
}

@Suite("AES-128-ECB và MD5")
struct SymmetricTests {
    @Test(arguments: aesVectors.indices)
    func aesMatchesOpenSSL(index: Int) throws {
        let vector = aesVectors[index]
        let key = Data(hex: vector.key)
        let encrypted = try AES128ECB.encrypt(Data(hex: vector.plaintext), key: key)
        #expect(encrypted.hex == vector.ciphertext)
        #expect(try AES128ECB.decrypt(encrypted, key: key).hex == vector.plaintext)
    }

    @Test(arguments: md5Vectors.indices)
    func md5MatchesHashlib(index: Int) {
        let vector = md5Vectors[index]
        #expect(MD5.hash(Data(hex: vector.input)).hex == vector.digest)
    }

    @Test func aesRejectsBadLengths() {
        #expect(throws: RFBCryptoError.self) { try AES128ECB.encrypt(Data(count: 15), key: Data(count: 16)) }
        #expect(throws: RFBCryptoError.self) { try AES128ECB.encrypt(Data(count: 16), key: Data(count: 15)) }
    }

    @Test func randomBytesHaveRequestedLengthAndDiffer() throws {
        let first = try SecureRandom.bytes(32)
        let second = try SecureRandom.bytes(32)
        #expect(first.count == 32)
        #expect(first != second)
    }
}
