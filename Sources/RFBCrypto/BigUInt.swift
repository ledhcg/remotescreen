import Foundation

/// Arbitrary-length unsigned integer, just enough for Diffie-Hellman and SRP.
///
/// iOS does not expose corecrypto's big-number API, so we implement it ourselves. Modular multiplication
/// uses Montgomery (see `MontgomeryContext`), with no big-number division.
///
/// **Does not run in constant time.** Fine for client-side DH in an interactive
/// session. Do not use it where local timing-attack resistance is needed.
public struct BigUInt: Equatable, Hashable, Sendable, Comparable {
    /// 64-bit limbs, least significant first, normalized (no trailing zero limb).
    var limbs: [UInt64]

    public init() {
        limbs = []
    }

    public init(_ value: UInt64) {
        limbs = value == 0 ? [] : [value]
    }

    init(limbs: [UInt64]) {
        self.limbs = limbs
        normalize()
    }

    /// Reads a number from big-endian bytes (the first byte is the most significant).
    public init<Bytes: Collection>(bigEndianBytes bytes: Bytes) where Bytes.Element == UInt8 {
        var result: [UInt64] = []
        var current: UInt64 = 0
        var shift: UInt64 = 0
        for byte in bytes.reversed() {
            current |= UInt64(byte) << shift
            shift += 8
            if shift == 64 {
                result.append(current)
                current = 0
                shift = 0
            }
        }
        if shift > 0 { result.append(current) }
        self.init(limbs: result)
    }

    private mutating func normalize() {
        while limbs.last == 0 { limbs.removeLast() }
    }

    public var isZero: Bool { limbs.isEmpty }
    public var isOdd: Bool { (limbs.first ?? 0) & 1 == 1 }

    /// Number of bits needed to represent it (0 if the number is zero).
    public var bitWidth: Int {
        guard let top = limbs.last else { return 0 }
        return limbs.count * 64 - top.leadingZeroBitCount
    }

    /// Bit number `index` counting from the lowest bit (bit 0).
    public func bit(at index: Int) -> Bool {
        let limb = index / 64
        guard index >= 0, limb < limbs.count else { return false }
        return (limbs[limb] >> UInt64(index % 64)) & 1 == 1
    }

    /// Exports as big-endian bytes. If `length` is greater than the natural length, pads with zeros at the front.
    /// If smaller, returns the natural length without truncating.
    public func bigEndianBytes(paddedTo length: Int = 0) -> [UInt8] {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(max(length, limbs.count * 8))
        for limb in limbs {
            for index in 0..<8 { bytes.append(UInt8(truncatingIfNeeded: limb >> UInt64(8 * index))) }
        }
        while bytes.last == 0 { bytes.removeLast() }
        if bytes.count < length { bytes.append(contentsOf: repeatElement(0, count: length - bytes.count)) }
        return bytes.reversed()
    }

    // MARK: - Comparison and basic arithmetic

    public static func < (lhs: BigUInt, rhs: BigUInt) -> Bool {
        compare(lhs.limbs, rhs.limbs) < 0
    }

    /// Compares two limb sequences using the same least-significant-first convention. Lengths may differ.
    static func compare(_ lhs: [UInt64], _ rhs: [UInt64]) -> Int {
        var lhsCount = lhs.count
        while lhsCount > 0 && lhs[lhsCount - 1] == 0 { lhsCount -= 1 }
        var rhsCount = rhs.count
        while rhsCount > 0 && rhs[rhsCount - 1] == 0 { rhsCount -= 1 }
        if lhsCount != rhsCount { return lhsCount < rhsCount ? -1 : 1 }
        var index = lhsCount - 1
        while index >= 0 {
            if lhs[index] != rhs[index] { return lhs[index] < rhs[index] ? -1 : 1 }
            index -= 1
        }
        return 0
    }

    /// The difference `lhs - rhs`. Requires `lhs >= rhs`.
    public static func + (lhs: BigUInt, rhs: BigUInt) -> BigUInt {
        var result: [UInt64] = []
        result.reserveCapacity(max(lhs.limbs.count, rhs.limbs.count) + 1)
        var carry: UInt64 = 0
        for index in 0..<max(lhs.limbs.count, rhs.limbs.count) {
            let (partial, overflowA) = (index < lhs.limbs.count ? lhs.limbs[index] : 0).addingReportingOverflow(index < rhs.limbs.count ? rhs.limbs[index] : 0)
            let (sum, overflowB) = partial.addingReportingOverflow(carry)
            result.append(sum)
            carry = (overflowA ? 1 : 0) + (overflowB ? 1 : 0)
        }
        if carry > 0 { result.append(carry) }
        return BigUInt(limbs: result)
    }

    public static func - (lhs: BigUInt, rhs: BigUInt) -> BigUInt {
        precondition(lhs >= rhs, "BigUInt: subtraction would be negative")
        var result = lhs.limbs
        var borrow: UInt64 = 0
        for index in 0..<result.count {
            let subtrahend = index < rhs.limbs.count ? rhs.limbs[index] : 0
            let (partial, overflow1) = result[index].subtractingReportingOverflow(subtrahend)
            let (difference, overflow2) = partial.subtractingReportingOverflow(borrow)
            result[index] = difference
            borrow = (overflow1 || overflow2) ? 1 : 0
        }
        return BigUInt(limbs: result)
    }

    public func shiftedLeft(by bits: Int) -> BigUInt {
        guard !isZero, bits > 0 else { return self }
        let limbShift = bits / 64
        let bitShift = UInt64(bits % 64)
        var result = [UInt64](repeating: 0, count: limbShift)
        var carry: UInt64 = 0
        for limb in limbs {
            if bitShift == 0 {
                result.append(limb)
            } else {
                result.append((limb << bitShift) | carry)
                carry = limb >> (64 - bitShift)
            }
        }
        if carry != 0 { result.append(carry) }
        return BigUInt(limbs: result)
    }

    /// Remainder of the division, computed by bitwise shift-subtract. Slow (O(n²)) but simple.
    /// Used only to prepare parameters, not in the hot loop of modexp.
    public func remainder(dividingBy modulus: BigUInt) -> BigUInt {
        precondition(!modulus.isZero, "BigUInt: chia cho 0")
        if self < modulus { return self }
        var remainder = BigUInt()
        var index = bitWidth - 1
        while index >= 0 {
            remainder = remainder.shiftedLeft(by: 1)
            if bit(at: index) {
                if remainder.limbs.isEmpty { remainder.limbs = [1] } else { remainder.limbs[0] |= 1 }
            }
            if remainder >= modulus { remainder = remainder - modulus }
            index -= 1
        }
        return remainder
    }

    /// Shifts right by `bits` bits (integer division by 2^bits).
    public func shiftedRight(by bits: Int) -> BigUInt {
        precondition(bits >= 0)
        let limbShift = bits / 64, bitShift = UInt64(bits % 64)
        guard limbShift < limbs.count else { return BigUInt() }
        var result = Array(limbs[limbShift...])
        if bitShift > 0 {
            for index in result.indices {
                let carry = index + 1 < result.count ? result[index + 1] << (64 - bitShift) : 0
                result[index] = (result[index] >> bitShift) | carry
            }
        }
        return BigUInt(limbs: result)
    }

    // MARK: - Modular exponentiation

    /// `self ^ exponent mod modulus`. `modulus` must be odd and greater than 1 (true for DH primes).
    public func modPow(_ exponent: BigUInt, modulus: BigUInt) -> BigUInt {
        precondition(modulus.isOdd && modulus.bitWidth > 1, "BigUInt.modPow only supports an odd modulus > 1")
        if exponent.isZero { return BigUInt(1) }
        let context = MontgomeryContext(modulus: modulus)
        return context.power(base: remainder(dividingBy: modulus), exponent: exponent)
    }
}
