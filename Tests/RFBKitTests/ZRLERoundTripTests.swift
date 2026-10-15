import CryptoKit
import Foundation
import Testing
@testable import RFBKit

/// Vectors produced by an independent ZRLE ENCODER written in Python (Tools/replay-check/make_zrle_fixture.py).
///
/// Reason for existing: real data from Apple's server contains only raw tiles (verified, see docs/protocol-notes.md), so
/// the other six tile types have no test against a real server. Here the correct pixels are known before encoding.
@Suite("ZRLE: cross-check against an independent encoder")
struct ZRLERoundTripTests {
    private func md5(_ bytes: [UInt8]) -> String {
        Insecure.MD5.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    @Test func decodesEveryTileKindThroughOnePersistentZlibStream() throws {
        var buffer = try Framebuffer(width: ZRLERoundTripVectors.width, height: ZRLERoundTripVectors.height)
        let decoder = try ZRLEDecoder() // one decoder for all rectangles: the zlib stream is continuous

        for rect in ZRLERoundTripVectors.rects {
            try decoder.decode(
                rect: PixelRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height),
                compressed: Data(hex: rect.compressed), into: &buffer
            )
        }
        #expect(md5(buffer.pixels) == ZRLERoundTripVectors.expectedMD5)
    }

    @Test func vectorsCoverAllSevenTileKinds() {
        // Guards the vector set itself: if someone regenerates it and loses a tile kind, this test fails immediately.
        let kinds = Set(ZRLERoundTripVectors.tileKinds)
        #expect(kinds.contains("raw"))
        #expect(kinds.contains("solid"))
        #expect(["pal2", "pal3", "pal4", "pal5", "pal9", "pal16"].allSatisfy(kinds.contains)) // all 3 bit widths
        #expect(kinds.contains("rle"))
        #expect(kinds.contains("rleLong")) // run > 255 → multi-byte length
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
            // A fresh zlib stream has no zlib header, nor the dictionary of the previous rectangle.
            try ZRLEDecoder().decode(
                rect: PixelRect(x: rects[1].x, y: rects[1].y, width: rects[1].width, height: rects[1].height),
                compressed: Data(hex: rects[1].compressed), into: &buffer
            )
        }
    }
}
