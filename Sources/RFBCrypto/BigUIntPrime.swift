import Foundation

extension BigUInt {
    /// Kiểm tra Miller-Rabin với cơ số ngẫu nhiên (lấy từ `SecRandomCopyBytes`).
    ///
    /// Hợp số lọt qua mỗi vòng với xác suất tối đa 1/4, nên `rounds` vòng cho sai số tối đa 4^-rounds, kể cả khi số bị chọn
    /// cố ý để qua mặt. Số nguyên tố luôn qua. Chi phí mỗi vòng là một lũy thừa modulo với số mũ cỡ chính số này.
    public func isProbablePrime(rounds: Int = 8) throws -> Bool {
        if self < BigUInt(4) { return self == BigUInt(2) || self == BigUInt(3) }
        guard isOdd else { return false }

        let one = BigUInt(1), two = BigUInt(2)
        let minusOne = self - one
        var squarings = 0
        while !minusOne.bit(at: squarings) { squarings += 1 }
        let oddPart = minusOne.shiftedRight(by: squarings)
        let baseRange = self - BigUInt(3) // cơ số trong [2, n-2]

        for _ in 0..<rounds {
            let random = BigUInt(bigEndianBytes: try SecureRandom.bytes(bitWidth / 8 + 8))
            let base = random.remainder(dividingBy: baseRange) + two
            var x = base.modPow(oddPart, modulus: self)
            if x == one || x == minusOne { continue }
            var reachedMinusOne = false
            for _ in 1..<max(squarings, 1) {
                x = x.modPow(two, modulus: self)
                if x == minusOne { reachedMinusOne = true; break }
                if x == one { return false }
            }
            if !reachedMinusOne { return false }
        }
        return true
    }
}
