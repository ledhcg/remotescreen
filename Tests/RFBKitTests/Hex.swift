import Foundation

extension Data {
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
}
