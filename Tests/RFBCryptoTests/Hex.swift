import Foundation
@testable import RFBCrypto

extension Data {
    /// Reads a hex string (odd length allowed: a leading zero is added automatically).
    init(hex: String) {
        let digits = hex.count.isMultiple(of: 2) ? hex : "0" + hex
        var bytes: [UInt8] = []
        var index = digits.startIndex
        while index < digits.endIndex {
            let next = digits.index(index, offsetBy: 2)
            bytes.append(UInt8(digits[index..<next], radix: 16)!)
            index = next
        }
        self.init(bytes)
    }

    var hex: String { map { String(format: "%02x", $0) }.joined() }
}

extension BigUInt {
    init(hex: String) {
        self.init(bigEndianBytes: Data(hex: hex))
    }
}
