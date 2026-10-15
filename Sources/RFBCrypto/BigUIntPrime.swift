import Foundation

extension BigUInt {
    /// Miller-Rabin test with random bases (taken from `SecRandomCopyBytes`).
    ///
    /// A composite passes each round with probability at most 1/4, so `rounds` rounds give an error of at most 4^-rounds, even when the number is chosen
    /// deliberately to fool the test. A prime always passes. Each round costs one modular exponentiation with an exponent about the size of the number itself.
    public func isProbablePrime(rounds: Int = 8) throws -> Bool {
        if self < BigUInt(4) { return self == BigUInt(2) || self == BigUInt(3) }
        guard isOdd else { return false }

        let one = BigUInt(1), two = BigUInt(2)
        let minusOne = self - one
        var squarings = 0
        while !minusOne.bit(at: squarings) { squarings += 1 }
        let oddPart = minusOne.shiftedRight(by: squarings)
        let baseRange = self - BigUInt(3) // base in [2, n-2]

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
