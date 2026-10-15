import CryptoKit
import Foundation
import Testing
@testable import RFBKit

@Suite("InflateStream (zlib liên tục)")
struct InflateStreamTests {
    @Test func keepsDictionaryAcrossChunks() throws {
        let stream = try InflateStream()
        let first = try stream.inflate(Data(hex: ZlibVectors.continuationFirst), maxOutput: 1 << 20)
        #expect(Data(first) == Data(hex: ZlibVectors.text))

        // Đoạn hai chỉ giải được vì tham chiếu ngược vào dữ liệu của đoạn một.
        let second = try stream.inflate(Data(hex: ZlibVectors.continuationSecond), maxOutput: 1 << 20)
        #expect(Data(second) == Data(hex: ZlibVectors.continuationSecondExpected))
    }

    @Test func aFreshStreamCannotDecodeTheSecondChunk() throws {
        // Đây chính là lỗi sẽ xảy ra nếu decoder tạo luồng zlib mới cho từng hình chữ nhật.
        let stream = try InflateStream()
        #expect(throws: RFBError.self) {
            try stream.inflate(Data(hex: ZlibVectors.continuationSecond), maxOutput: 1 << 20)
        }
    }

    @Test func outputLargerThanTheInternalBufferIsCompleteAndExact() throws {
        let output = try InflateStream().inflate(Data(hex: ZlibVectors.bigCompressed), maxOutput: 1 << 20)
        #expect(output.count == ZlibVectors.bigLength)
        #expect(output.count > 4 * 64 * 1024)
        #expect(Insecure.MD5.hash(data: output).map { String(format: "%02x", $0) }.joined() == ZlibVectors.bigMD5)
    }

    /// Lưu ý thiết kế: zlib chỉ kiểm tra Adler32 ở cuối luồng, mà luồng RFB không bao giờ kết thúc, nên một bit
    /// bị đảo giữa luồng vẫn giải ra dữ liệu sai mà không báo lỗi. Việc phát hiện lệch luồng phải nhờ các kiểm
    /// tra của ZRLE (byte thừa/thiếu, lượt chạy vượt tile, chỉ số palette sai). Ở đây chỉ kiểm tra lỗi cấu trúc
    /// zlib mà thư viện thật sự bắt được.
    @Test func structurallyInvalidDataThrows() throws {
        #expect(throws: RFBError.self) {
            try InflateStream().inflate(Data(hex: ZlibVectors.corrupted), maxOutput: 1 << 20)
        }
    }

    @Test func outputCapStopsZipBombs() throws {
        let bomb = Data(hex: ZlibVectors.bomb)
        #expect(bomb.count < 4096)
        #expect(throws: RFBError.self) { try InflateStream().inflate(bomb, maxOutput: 1 << 20) }

        let allowed = try InflateStream().inflate(bomb, maxOutput: 4 << 20)
        #expect(allowed.count == ZlibVectors.bombLength)
        #expect(allowed.allSatisfy { $0 == 0 })
    }

    @Test func emptyInputProducesEmptyOutput() throws {
        #expect(try InflateStream().inflate(Data(), maxOutput: 100).isEmpty)
    }
}
