import CryptoKit
import Foundation
import Testing
@testable import RFBKit

/// Vector do một bộ MÃ HÓA ZRLE độc lập viết bằng Python tạo ra (Tools/replay-check/make_zrle_fixture.py).
///
/// Lý do tồn tại: dữ liệu thật từ server Apple chỉ chứa tile raw (đã kiểm chứng, xem docs/protocol-notes.md), nên
/// sáu loại tile còn lại không có bài kiểm tra nào với server thật. Ở đây pixel đúng được biết trước khi mã hóa.
@Suite("ZRLE: đối chiếu với bộ mã hóa độc lập")
struct ZRLERoundTripTests {
    private func md5(_ bytes: [UInt8]) -> String {
        Insecure.MD5.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    @Test func decodesEveryTileKindThroughOnePersistentZlibStream() throws {
        var buffer = try Framebuffer(width: ZRLERoundTripVectors.width, height: ZRLERoundTripVectors.height)
        let decoder = try ZRLEDecoder() // một decoder cho mọi hình chữ nhật: luồng zlib liên tục

        for rect in ZRLERoundTripVectors.rects {
            try decoder.decode(
                rect: PixelRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height),
                compressed: Data(hex: rect.compressed), into: &buffer
            )
        }
        #expect(md5(buffer.pixels) == ZRLERoundTripVectors.expectedMD5)
    }

    @Test func vectorsCoverAllSevenTileKinds() {
        // Bảo vệ chính bộ vector: nếu ai đó sinh lại mà làm mất một loại tile, test này báo ngay.
        let kinds = Set(ZRLERoundTripVectors.tileKinds)
        #expect(kinds.contains("raw"))
        #expect(kinds.contains("solid"))
        #expect(["pal2", "pal3", "pal4", "pal5", "pal9", "pal16"].allSatisfy(kinds.contains)) // cả 3 độ rộng bit
        #expect(kinds.contains("rle"))
        #expect(kinds.contains("rleLong")) // lượt chạy > 255 → byte độ dài nhiều lượt
        #expect(kinds.contains("prle3"))
        #expect(kinds.contains("prle40"))
    }

    @Test func aFreshDecoderPerRectangleCannotDecodeTheSecond() throws {
        var buffer = try Framebuffer(width: ZRLERoundTripVectors.width, height: ZRLERoundTripVectors.height)
        let rects = ZRLERoundTripVectors.rects
        try ZRLEDecoder().decode(
            rect: PixelRect(x: rects[0].x, y: rects[0].y, width: rects[0].width, height: rects[0].height),
            compressed: Data(hex: rects[0].compressed), into: &buffer
        )
        #expect(throws: RFBError.self) {
            // Luồng zlib mới không có tiêu đề zlib, cũng không có từ điển của hình chữ nhật trước.
            try ZRLEDecoder().decode(
                rect: PixelRect(x: rects[1].x, y: rects[1].y, width: rects[1].width, height: rects[1].height),
                compressed: Data(hex: rects[1].compressed), into: &buffer
            )
        }
    }
}
