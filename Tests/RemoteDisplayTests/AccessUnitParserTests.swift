import Foundation
import Testing
@testable import RemoteDisplay

@Suite("Video: access unit parser")
struct AccessUnitParserTests {
    private func unit(_ nals: [[UInt8]], lengthSize: Int = 4) -> Data {
        var bytes = [UInt8]()
        for nal in nals {
            for shift in stride(from: (lengthSize - 1) * 8, through: 0, by: -8) { bytes.append(UInt8(truncatingIfNeeded: nal.count >> shift)) }
            bytes += nal
        }
        return Data(bytes)
    }

    @Test func acceptsWellFormedUnits() {
        #expect(AccessUnitParser.validate(unit([[0x26, 1, 2], [0x02, 9]]), lengthSize: 4) == .success(2))
        #expect(AccessUnitParser.validate(unit([[0x65, 1]], lengthSize: 2), lengthSize: 2) == .success(1))
        #expect(AccessUnitParser.validate(unit([[0x65]], lengthSize: 1), lengthSize: 1) == .success(1))
    }

    @Test func rejectsEmptyTruncatedAndOversizedLengths() {
        #expect(AccessUnitParser.validate(Data(), lengthSize: 4) == .failure(.empty))
        #expect(AccessUnitParser.validate(Data([0, 0, 0]), lengthSize: 4) == .failure(.truncatedLength))
        #expect(AccessUnitParser.validate(Data([0, 0, 0, 0, 0x26]), lengthSize: 4) == .failure(.zeroLengthNAL))
        #expect(AccessUnitParser.validate(Data([0, 0, 0, 9, 0x26, 1]), lengthSize: 4) == .failure(.lengthExceedsData))
        #expect(AccessUnitParser.validate(Data([0xFF, 0xFF, 0xFF, 0xFF, 0x26]), lengthSize: 4) == .failure(.lengthExceedsData))
        // Trailing bytes that do not form a NAL are not ignored.
        #expect(AccessUnitParser.validate(unit([[0x26, 1]]) + Data([0, 0]), lengthSize: 4) == .failure(.truncatedLength))
        #expect(AccessUnitParser.validate(unit([[0x80, 1]]), lengthSize: 4) == .failure(.forbiddenBit))
    }

    @Test func capsTheNumberOfNALUnits() {
        let many = unit(Array(repeating: [0x02, 1], count: AccessUnitParser.maxNALUnits + 1))
        #expect(AccessUnitParser.validate(many, lengthSize: 4) == .failure(.tooManyNALUnits))
    }

    @Test func dimensionLimits() {
        #expect(AccessUnitParser.validateDimensions(width: 1920, height: 1080))
        #expect(AccessUnitParser.validateDimensions(width: 16384, height: 2048))
        #expect(!AccessUnitParser.validateDimensions(width: 0, height: 100))
        #expect(!AccessUnitParser.validateDimensions(width: 100, height: -1))
        #expect(!AccessUnitParser.validateDimensions(width: 16385, height: 100))
        #expect(!AccessUnitParser.validateDimensions(width: 16384, height: 16384)) // 256M pixels
    }

    @Test func rejectsHostileConfigs() {
        let good = Data([0x40, 1, 2])
        func config(_ sets: [Data], codec: VideoCodec = .hevc, lengthSize: Int = 4, depth: Int = 8) -> VideoStreamConfig {
            VideoStreamConfig(codec: codec, parameterSets: sets, nalLengthSize: lengthSize, bitDepth: depth)
        }
        #expect(throws: VideoStreamError.self) { try AccessUnitParser.validate(config([good])) } // HEVC needs three
        #expect(throws: VideoStreamError.self) { try AccessUnitParser.validate(config([good, good, Data()])) }
        #expect(throws: VideoStreamError.self) { try AccessUnitParser.validate(config([good, good, Data(count: 5000)])) }
        #expect(throws: VideoStreamError.self) { try AccessUnitParser.validate(config(Array(repeating: good, count: 17))) }
        #expect(throws: VideoStreamError.self) { try AccessUnitParser.validate(config([good, good, good], lengthSize: 0)) }
        #expect(throws: VideoStreamError.self) { try AccessUnitParser.validate(config([good, good, good], lengthSize: 8)) }
        #expect(throws: VideoStreamError.self) { try AccessUnitParser.validate(config([good, good, good], depth: 12)) }
        #expect(throws: VideoStreamError.self) { try AccessUnitParser.validate(config([good, Data([0x80])], codec: .h264)) }
        #expect(throws: Never.self) { try AccessUnitParser.validate(config([good, good], codec: .h264)) }
    }
}

/// The parser reads lengths from an untrusted peer. Seeded random and mutated access units must always yield a verdict without trapping, and
/// whenever the verdict is `success` the structure must really tile the buffer.
@Suite("Video: access unit fuzz")
struct AccessUnitFuzzTests {
    private struct SplitMix64: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    private static let interesting: [UInt8] = [0, 1, 2, 3, 4, 127, 128, 129, 254, 255]

    private static func wellFormed(_ random: inout SplitMix64, lengthSize: Int) -> [UInt8] {
        var bytes = [UInt8]()
        for _ in 0..<Int.random(in: 1...6, using: &random) {
            let count = Int.random(in: 1...40, using: &random)
            for shift in stride(from: (lengthSize - 1) * 8, through: 0, by: -8) { bytes.append(UInt8(truncatingIfNeeded: count >> shift)) }
            bytes.append(UInt8.random(in: 0...0x7F, using: &random))
            bytes += (1..<count).map { _ in UInt8.random(in: 0...255, using: &random) }
        }
        return bytes
    }

    /// Re-walks the buffer independently of the parser.
    private static func tiles(_ bytes: [UInt8], lengthSize: Int, count: Int) -> Bool {
        var offset = 0, nals = 0
        while offset < bytes.count {
            guard offset + lengthSize <= bytes.count else { return false }
            let length = bytes[offset..<offset + lengthSize].reduce(0) { ($0 << 8) | Int($1) }
            offset += lengthSize + length
            nals += 1
            guard length > 0, offset <= bytes.count else { return false }
        }
        return nals == count
    }

    @Test func mutatedAndRandomUnitsNeverTrap() {
        var random = SplitMix64(state: 0xA11CE)
        var accepted = 0
        for iteration in 0..<5000 {
            let lengthSize = [1, 2, 3, 4].randomElement(using: &random)!
            var bytes = Self.wellFormed(&random, lengthSize: lengthSize)
            if iteration % 5 == 4 { // pure noise
                bytes = (0..<Int.random(in: 0...64, using: &random)).map { _ in UInt8.random(in: 0...255, using: &random) }
            } else {
                for _ in 0..<Int.random(in: 0...4, using: &random) where !bytes.isEmpty {
                    switch Int.random(in: 0..<4, using: &random) {
                    case 0: bytes[Int.random(in: 0..<bytes.count, using: &random)] = Self.interesting.randomElement(using: &random)!
                    case 1: bytes.removeLast(Int.random(in: 1...bytes.count, using: &random))
                    case 2: bytes.insert(UInt8.random(in: 0...255, using: &random), at: Int.random(in: 0...bytes.count, using: &random))
                    default: bytes[Int.random(in: 0..<bytes.count, using: &random)] ^= UInt8(1 << Int.random(in: 0..<8, using: &random))
                    }
                }
            }
            if case .success(let count) = AccessUnitParser.validate(Data(bytes), lengthSize: lengthSize) {
                accepted += 1
                #expect(Self.tiles(bytes, lengthSize: lengthSize, count: count))
            }
        }
        #expect(accepted > 0) // the generator does produce valid units, so both verdicts are exercised
    }
}
