import Foundation

/// Montgomery multiplication with 64-bit limbs (CIOS algorithm).
///
/// For an odd modulus `n` of `k` limbs, Montgomery multiplication computes `a·b·R⁻¹ mod n` (R = 2^(64k))
/// using only multiplication and addition, with no division. This makes 4096-bit modular exponentiation fast
/// without implementing big-number division.
struct MontgomeryContext {
    private let modulus: [UInt64]
    private let width: Int
    /// `-n⁻¹ mod 2^64`.
    private let negatedInverse: UInt64
    /// `R² mod n`, used to convert a number to Montgomery form.
    private let rSquared: [UInt64]

    init(modulus value: BigUInt) {
        modulus = value.limbs
        width = value.limbs.count

        // Inverse of the lowest limb modulo 2^64 by Newton iteration:
        // for odd n, x = n is already correct to 3 bits, and each round doubles the number of correct bits (3→6→…→96).
        let low = value.limbs[0]
        var inverse = low
        for _ in 0..<6 { inverse = inverse &* (2 &- low &* inverse) }
        negatedInverse = 0 &- inverse

        let reduced = BigUInt(1).shiftedLeft(by: 128 * value.limbs.count).remainder(dividingBy: value)
        rSquared = Self.padded(reduced.limbs, to: value.limbs.count)
    }

    private static func padded(_ limbs: [UInt64], to count: Int) -> [UInt64] {
        limbs + [UInt64](repeating: 0, count: count - limbs.count)
    }

    func power(base: BigUInt, exponent: BigUInt) -> BigUInt {
        let baseInMontgomery = multiply(Self.padded(base.limbs, to: width), rSquared)
        var accumulator = baseInMontgomery // the top bit of the exponent is always 1

        var index = exponent.bitWidth - 2
        while index >= 0 {
            accumulator = multiply(accumulator, accumulator)
            if exponent.bit(at: index) { accumulator = multiply(accumulator, baseInMontgomery) }
            index -= 1
        }

        var one = [UInt64](repeating: 0, count: width)
        one[0] = 1
        return BigUInt(limbs: multiply(accumulator, one)) // convert back to normal form
    }

    /// `a·b·R⁻¹ mod n`. Both inputs must have exactly `width` limbs and be less than `n`.
    private func multiply(_ a: [UInt64], _ b: [UInt64]) -> [UInt64] {
        var t = [UInt64](repeating: 0, count: width + 2)

        for i in 0..<width {
            // t += a · b[i]
            var carry: UInt64 = 0
            let multiplier = b[i]
            for j in 0..<width {
                let (high, low) = a[j].multipliedFullWidth(by: multiplier)
                let (sum1, carry1) = t[j].addingReportingOverflow(low)
                let (sum2, carry2) = sum1.addingReportingOverflow(carry)
                t[j] = sum2
                carry = high &+ (carry1 ? 1 : 0) &+ (carry2 ? 1 : 0)
            }
            let (top, topCarry) = t[width].addingReportingOverflow(carry)
            t[width] = top
            t[width + 1] = topCarry ? 1 : 0

            // t = (t + m·n) / 2^64, with m chosen so that the lowest limb cancels out.
            let m = t[0] &* negatedInverse
            let (firstHigh, firstLow) = m.multipliedFullWidth(by: modulus[0])
            let (_, firstCarry) = t[0].addingReportingOverflow(firstLow)
            carry = firstHigh &+ (firstCarry ? 1 : 0)
            for j in 1..<width {
                let (high, low) = m.multipliedFullWidth(by: modulus[j])
                let (sum1, carry1) = t[j].addingReportingOverflow(low)
                let (sum2, carry2) = sum1.addingReportingOverflow(carry)
                t[j - 1] = sum2
                carry = high &+ (carry1 ? 1 : 0) &+ (carry2 ? 1 : 0)
            }
            let (merged, mergedCarry) = t[width].addingReportingOverflow(carry)
            t[width - 1] = merged
            t[width] = t[width + 1] &+ (mergedCarry ? 1 : 0)
        }

        var result = Array(t[0..<width])
        if t[width] != 0 || BigUInt.compare(result, modulus) >= 0 {
            var borrow: UInt64 = 0
            for index in 0..<width {
                let (partial, overflow1) = result[index].subtractingReportingOverflow(modulus[index])
                let (difference, overflow2) = partial.subtractingReportingOverflow(borrow)
                result[index] = difference
                borrow = (overflow1 || overflow2) ? 1 : 0
            }
        }
        return result
    }
}
