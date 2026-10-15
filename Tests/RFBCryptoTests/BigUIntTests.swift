import Foundation
import Testing
@testable import RFBCrypto

@Suite("BigUInt")
struct BigUIntTests {
    @Test(arguments: bigUIntVectors.indices)
    func modPowMatchesPython(index: Int) {
        let vector = bigUIntVectors[index]
        let result = BigUInt(hex: vector.base).modPow(BigUInt(hex: vector.exponent), modulus: BigUInt(hex: vector.modulus))
        #expect(result == BigUInt(hex: vector.result), "\(vector.name)")
    }

    @Test func zeroExponentGivesOne() {
        #expect(BigUInt(7).modPow(BigUInt(), modulus: BigUInt(13)) == BigUInt(1))
    }

    @Test func bytesRoundTrip() {
        let bytes: [UInt8] = [0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A]
        let value = BigUInt(bigEndianBytes: bytes)
        #expect(value.bigEndianBytes() == bytes)
        #expect(value.bitWidth == 10 * 8 - 7) // the first byte 0x01 takes up only 1 bit
    }

    @Test func leadingZeroBytesAreIgnoredAndPaddingIsRestored() {
        let value = BigUInt(bigEndianBytes: [0, 0, 0, 0xFF])
        #expect(value == BigUInt(255))
        #expect(value.bigEndianBytes(paddedTo: 6) == [0, 0, 0, 0, 0, 0xFF])
        #expect(value.bigEndianBytes(paddedTo: 0) == [0xFF])
    }

    @Test func zeroHasNoBits() {
        let zero = BigUInt(bigEndianBytes: [UInt8]())
        #expect(zero.isZero)
        #expect(zero.bitWidth == 0)
        #expect(zero.bigEndianBytes(paddedTo: 3) == [0, 0, 0])
    }

    @Test func orderingAndSubtraction() {
        let big = BigUInt(hex: "ffffffffffffffffffffffffffffffff")
        let small = BigUInt(hex: "10000000000000000")
        #expect(small < big)
        #expect(!(big < small))
        #expect(big - big == BigUInt())
        // Borrow across several limbs: 2^128 - 1 - 2^64 = 0xffff...ffff0000...0000 - ... check with hex
        #expect(big - small == BigUInt(hex: "fffffffffffffffeffffffffffffffff"))
    }

    @Test func shiftAndRemainder() {
        #expect(BigUInt(1).shiftedLeft(by: 130).bitWidth == 131)
        // 2^128 mod 1000003 = 3026 (0xbd2), computed with Python pow(2, 128, 1000003).
        #expect(BigUInt(1).shiftedLeft(by: 128).remainder(dividingBy: BigUInt(1_000_003)) == BigUInt(3026))
    }

    /// Measures time to verify the performance claim with Apple's real parameters (4096-bit).
    /// Asserts only a very loose bound (to catch degenerate behavior); the printed numbers are the actual measurement.
    @Test func timingAtRealParameterSizes() {
        let vector = bigUIntVectors[0] // 4096-bit, 512-bit exponent
        let full = bigUIntVectors[1] // 4096-bit, 4096-bit exponent
        let clock = ContinuousClock()

        let short = clock.measure {
            _ = BigUInt(hex: vector.base).modPow(BigUInt(hex: vector.exponent), modulus: BigUInt(hex: vector.modulus))
        }
        let long = clock.measure {
            _ = BigUInt(hex: full.base).modPow(BigUInt(hex: full.exponent), modulus: BigUInt(hex: full.modulus))
        }
        print("⏱ modPow 4096-bit, 512-bit exponent : \(short)")
        print("⏱ modPow 4096-bit, 4096-bit exponent: \(long)")
        #expect(short < .seconds(20))
        #expect(long < .seconds(60))
    }
}
