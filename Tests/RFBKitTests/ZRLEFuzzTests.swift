import Foundation
import Testing
@testable import RFBKit

/// Bộ giải mã ZRLE ghi bằng con trỏ nên an toàn bộ nhớ phụ thuộc vào các phép kiểm biên tường minh. Bài này ném dữ liệu ngẫu nhiên
/// (thiên về các header tile hợp lệ) vào nhiều hình chữ nhật, và đòi hai điều: không bao giờ sập, và **không bao giờ ghi ra ngoài
/// hình chữ nhật được giải mã**, kể cả khi dữ liệu sai và giải mã dừng giữa chừng.
@Suite("ZRLE: fuzz an toàn bộ nhớ")
struct ZRLEFuzzTests {
    /// Bộ sinh số ngẫu nhiên có hạt giống, để lần chạy nào hỏng cũng tái hiện được.
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
        let width = 70, height = 66 // hơn một tile 64 mỗi chiều, nên có tile cụt ở mép; nhỏ để không chiếm CPU của test khác
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
                // Một nửa số byte là header "có nghĩa", nửa còn lại ngẫu nhiên hoàn toàn.
                bytes.append(Bool.random(using: &random) ? interestingHeaders.randomElement(using: &random)! : UInt8.random(in: 0...255, using: &random))
            }

            // Thành công hay ném lỗi đều được. Chỉ cấm sập và ghi lố.
            _ = try? ZRLEDecoder.decodeTiles(bytes, rect: rect, into: &buffer)

            let pixels = buffer.pixels
            for y in 0..<height {
                for x in 0..<width where !(rect.x..<rect.x + rect.width).contains(x) || !(rect.y..<rect.y + rect.height).contains(y) {
                    let offset = (y * width + x) * 4
                    #expect(
                        pixels[offset] == Self.sentinel && pixels[offset + 1] == Self.sentinel && pixels[offset + 2] == Self.sentinel,
                        "ghi ra ngoài \(rect) tại (\(x), \(y)), hạt giống \(seed)"
                    )
                    if pixels[offset] != Self.sentinel { return } // một lỗi là đủ, đừng in cả triệu dòng
                }
            }
        }
    }
}
