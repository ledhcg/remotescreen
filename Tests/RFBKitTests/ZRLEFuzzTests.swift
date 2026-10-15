import Foundation
import Testing
@testable import RFBKit

/// The ZRLE decoder writes through pointers, so memory safety depends on explicit bounds checks. This test throws random data
/// (biased toward valid tile headers) at many rectangles, and demands two things: it never crashes, and it **never writes outside
/// the rectangle being decoded**, even when the data is wrong and decoding stops midway.
@Suite("ZRLE: memory-safety fuzz")
struct ZRLEFuzzTests {
    /// Seeded random number generator, so any failing run can be reproduced.
    private struct SplitMix64: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
    }

    private static let sentinel: UInt8 = 0xAB

    @Test(arguments: [1, 2, 3, 4])
    func randomDataNeverWritesOutsideTheRectAndNeverCrashes(seed: UInt64) throws {
        var random = SplitMix64(state: seed)
        let width = 70, height = 66 // more than one 64 tile per dimension, so there are truncated tiles at the edge; small so it does not take CPU from other tests
        let interestingHeaders: [UInt8] = [0, 1, 2, 3, 4, 5, 15, 16, 17, 127, 128, 129, 130, 131, 255]

        for _ in 0..<400 {
            var buffer = try Framebuffer(width: width, height: height)
            try buffer.write(buffer.bounds, bgra: [UInt8](repeating: Self.sentinel, count: width * height * 4))

            let rectWidth = Int.random(in: 1...width, using: &random)
            let rectHeight = Int.random(in: 1...height, using: &random)
            let rect = PixelRect(
                x: Int.random(in: 0...(width - rectWidth), using: &random),
                y: Int.random(in: 0...(height - rectHeight), using: &random),
                width: rectWidth, height: rectHeight
            )

            var bytes: [UInt8] = []
            for _ in 0..<Int.random(in: 0...6_000, using: &random) {
                // Half of the bytes are "meaningful" headers, the other half completely random.
                bytes.append(Bool.random(using: &random) ? interestingHeaders.randomElement(using: &random)! : UInt8.random(in: 0...255, using: &random))
            }

            // Either success or a thrown error is fine. Only crashing and writing out of bounds are forbidden.
            _ = try? ZRLEDecoder.decodeTiles(bytes, rect: rect, into: &buffer)

            let pixels = buffer.pixels
            for y in 0..<height {
                for x in 0..<width where !(rect.x..<rect.x + rect.width).contains(x) || !(rect.y..<rect.y + rect.height).contains(y) {
                    let offset = (y * width + x) * 4
                    #expect(
                        pixels[offset] == Self.sentinel && pixels[offset + 1] == Self.sentinel && pixels[offset + 2] == Self.sentinel,
                        "wrote outside \(rect) at (\(x), \(y)), seed \(seed)"
                    )
                    if pixels[offset] != Self.sentinel { return } // one error is enough, do not print a million lines
                }
            }
        }
    }
}
