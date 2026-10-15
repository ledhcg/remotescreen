import CoreGraphics
import Foundation
import Testing
@testable import RFBKit

/// BGRA pixel (fourth byte is padding) from an RGB color.
func bgra(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> [UInt8] { [b, g, r, 0] }

@Suite("Framebuffer")
struct FramebufferTests {
    @Test func startsBlackWithExpectedSize() throws {
        let buffer = try Framebuffer(width: 3, height: 2)
        #expect(buffer.pixels.count == 3 * 2 * 4)
        #expect(buffer.rgb(x: 2, y: 1)! == (0, 0, 0))
        #expect(buffer.rgb(x: 3, y: 0) == nil)
    }

    @Test(arguments: [(0, 5), (5, 0), (-1, 5), (16_385, 5), (5, 16_385)])
    func rejectsInvalidDimensions(width: Int, height: Int) {
        #expect(throws: RFBError.self) { try Framebuffer(width: width, height: height) }
    }

    @Test func writesRowsAtTheRightOffsets() throws {
        var buffer = try Framebuffer(width: 4, height: 3)
        // 2x2 rectangle at (1,1): row 0 is red, green; row 1 is blue, white.
        let data = Data(bgra(255, 0, 0) + bgra(0, 255, 0) + bgra(0, 0, 255) + bgra(255, 255, 255))
        try buffer.write(PixelRect(x: 1, y: 1, width: 2, height: 2), bgra: data)

        #expect(buffer.rgb(x: 1, y: 1)! == (255, 0, 0))
        #expect(buffer.rgb(x: 2, y: 1)! == (0, 255, 0))
        #expect(buffer.rgb(x: 1, y: 2)! == (0, 0, 255))
        #expect(buffer.rgb(x: 2, y: 2)! == (255, 255, 255))
        #expect(buffer.rgb(x: 0, y: 0)! == (0, 0, 0)) // outside the written region it stays black
        #expect(buffer.rgb(x: 3, y: 2)! == (0, 0, 0))
    }

    @Test func rejectsWritesOutsideOrWithWrongLength() throws {
        var buffer = try Framebuffer(width: 4, height: 4)
        #expect(throws: RFBError.self) {
            try buffer.write(PixelRect(x: 3, y: 0, width: 2, height: 1), bgra: Data(count: 8))
        }
        #expect(throws: RFBError.self) {
            try buffer.write(PixelRect(x: -1, y: 0, width: 1, height: 1), bgra: Data(count: 4))
        }
        #expect(throws: RFBError.self) {
            try buffer.write(PixelRect(x: 0, y: 0, width: 2, height: 1), bgra: Data(count: 7))
        }
        #expect(throws: RFBError.self) {
            try buffer.write(PixelRect(x: 0, y: 0, width: 0, height: 1), bgra: Data())
        }
    }

    @Test func copyRectBehavesLikeMemmoveWhenRegionsOverlap() throws {
        var buffer = try Framebuffer(width: 4, height: 1)
        let colours = [(10, 0, 0), (20, 0, 0), (30, 0, 0), (40, 0, 0)].map { bgra(UInt8($0.0), UInt8($0.1), UInt8($0.2)) }
        try buffer.write(PixelRect(x: 0, y: 0, width: 4, height: 1), bgra: Data(colours.flatMap { $0 }))

        // Copy the first 3 pixels to position x=1. Copying forward pixel by pixel without capturing first would give 10,10,10,10.
        try buffer.copy(from: PixelRect(x: 0, y: 0, width: 3, height: 1), toX: 1, y: 0)
        #expect((0..<4).map { buffer.rgb(x: $0, y: 0)!.r } == [10, 10, 20, 30])
    }

    @Test func copyRectRejectsRegionsOutsideTheBuffer() throws {
        var buffer = try Framebuffer(width: 4, height: 4)
        #expect(throws: RFBError.self) { try buffer.copy(from: PixelRect(x: 0, y: 0, width: 2, height: 2), toX: 3, y: 3) }
        #expect(throws: RFBError.self) { try buffer.copy(from: PixelRect(x: 3, y: 3, width: 2, height: 2), toX: 0, y: 0) }
    }

    @Test func producesCGImageOfSameSize() throws {
        let buffer = try Framebuffer(width: 5, height: 3)
        let image = try #require(buffer.makeCGImage())
        #expect(image.width == 5)
        #expect(image.height == 3)
    }
}
