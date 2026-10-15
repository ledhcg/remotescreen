import Foundation
import Testing
@testable import RFBKit

@Suite("CursorImage")
struct CursorImageTests {
    @Test func appliesTheBitmaskMostSignificantBitFirst() throws {
        // 2×2: BGRA pixels (4 bytes), then a 1-byte mask per row.
        let pixels = Data([1, 2, 3, 0, 4, 5, 6, 0, 7, 8, 9, 0, 10, 11, 12, 0])
        let mask = Data([0b1000_0000, 0b0100_0000]) // row 0: (0,0) opaque; row 1: (1,1) opaque
        let cursor = try CursorImage(width: 2, height: 2, hotspotX: 1, hotspotY: 0, pixels: pixels, mask: mask)

        #expect(cursor.bgra == [1, 2, 3, 255, 0, 0, 0, 0, 0, 0, 0, 0, 10, 11, 12, 255])
        #expect(cursor.hotspotX == 1)
        #expect(cursor.hotspotY == 0)
        #expect(!cursor.isEmpty)
    }

    @Test func maskRowsPadToWholeBytes() throws {
        // 9 pixels wide: 2 mask bytes per row. Only pixel x=8 (the high bit of the second byte) is opaque.
        let cursor = try CursorImage(
            width: 9, height: 1, hotspotX: 0, hotspotY: 0,
            pixels: Data((0..<9).flatMap { [UInt8($0), 0, 0, 0] }), mask: Data([0x00, 0x80])
        )
        let alphas = (0..<9).map { cursor.bgra[$0 * 4 + 3] }
        #expect(alphas == [0, 0, 0, 0, 0, 0, 0, 0, 255])
        #expect(cursor.bgra[8 * 4] == 8)
    }

    @Test func rejectsMismatchedSizesAndHugeCursors() {
        #expect(throws: RFBError.self) {
            try CursorImage(width: 2, height: 2, hotspotX: 0, hotspotY: 0, pixels: Data(count: 15), mask: Data(count: 2))
        }
        #expect(throws: RFBError.self) {
            try CursorImage(width: 2, height: 2, hotspotX: 0, hotspotY: 0, pixels: Data(count: 16), mask: Data(count: 1))
        }
        #expect(throws: RFBError.self) {
            try CursorImage(width: 1025, height: 1, hotspotX: 0, hotspotY: 0, pixels: Data(), mask: Data())
        }
    }

    @Test func emptyCursorHasNoPixels() {
        #expect(CursorImage.empty.isEmpty)
        #expect(CursorImage.empty.bgra.isEmpty)
    }
}

@Suite("CursorImage: default image and building from BGRA")
struct DefaultCursorTests {
    @Test func defaultArrowHasAnOpaqueTipAndATransparentCorner() throws {
        let arrow = CursorImage.defaultArrow
        #expect(!arrow.isEmpty)
        #expect(arrow.hotspotX == 0 && arrow.hotspotY == 0)
        #expect(arrow.bgra.count == arrow.width * arrow.height * 4)
        // Hot spot (0, 0) is an opaque black outline. The top-right corner is fully transparent.
        #expect(Array(arrow.bgra[0..<4]) == [0, 0, 0, 255])
        let topRight = (arrow.width - 1) * 4
        #expect(Array(arrow.bgra[topRight..<topRight + 4]) == [0, 0, 0, 0])
    }

    @Test func everyPixelIsEitherFullyTransparentOrFullyOpaque() {
        // The renderer relies on this so linear sampling produces no stray fringes.
        let alphas = stride(from: 3, to: CursorImage.defaultArrow.bgra.count, by: 4).map { CursorImage.defaultArrow.bgra[$0] }
        #expect(alphas.allSatisfy { $0 == 0 || $0 == 255 })
        #expect(alphas.contains(0) && alphas.contains(255))
    }

    @Test func transparentPixelsHaveZeroColourSoPremultipliedBlendingIsExact() {
        let bgra = CursorImage.defaultArrow.bgra
        for i in stride(from: 0, to: bgra.count, by: 4) where bgra[i + 3] == 0 {
            #expect(bgra[i] == 0 && bgra[i + 1] == 0 && bgra[i + 2] == 0)
        }
    }

    @Test func initFromBGRARejectsWrongByteCountAndHugeSizes() {
        #expect(CursorImage(width: 2, height: 2, hotspotX: 0, hotspotY: 0, bgra: [UInt8](repeating: 0, count: 15)) == nil)
        #expect(CursorImage(width: CursorImage.maxDimension + 1, height: 1, hotspotX: 0, hotspotY: 0, bgra: []) == nil)
        #expect(CursorImage(width: 2, height: 2, hotspotX: 1, hotspotY: 1, bgra: [UInt8](repeating: 0, count: 16)) != nil)
    }
}
