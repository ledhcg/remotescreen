import Foundation
import Testing
@testable import RFBKit

@Suite("Framebuffer.difference")
struct FramebufferDifferenceTests {
    @Test func identicalBuffersHaveNoDifference() throws {
        let a = try Framebuffer(width: 4, height: 3)
        #expect(a.difference(from: a) == Framebuffer.Difference(count: 0, bounds: nil))
    }

    @Test func reportsCountAndSmallestBoundingRectangle() throws {
        let a = try Framebuffer(width: 5, height: 4)
        var b = a
        try b.write(PixelRect(x: 1, y: 1, width: 1, height: 1), bgra: [1, 2, 3, 0])
        try b.write(PixelRect(x: 3, y: 2, width: 1, height: 1), bgra: [9, 9, 9, 0])
        let difference = try #require(a.difference(from: b))
        #expect(difference.count == 2)
        #expect(difference.bounds == PixelRect(x: 1, y: 1, width: 3, height: 2))
    }

    @Test func paddingByteIsIgnored() throws {
        let a = try Framebuffer(width: 2, height: 1)
        var b = a
        try b.write(PixelRect(x: 0, y: 0, width: 1, height: 1), bgra: [0, 0, 0, 200]) // only the padding byte differs
        #expect(a.difference(from: b)?.count == 0)
    }

    @Test func cellsLocateDifferencesAndClipAtTheEdges() throws {
        let a = try Framebuffer(width: 300, height: 200)
        var b = a
        // Two pixels in cell (0,0), one pixel in the last column (x=299, cell width 44) and one in the last row (y=199, cell height 72).
        for (x, y) in [(5, 5), (6, 5), (299, 10), (10, 199)] {
            try b.write(PixelRect(x: x, y: y, width: 1, height: 1), bgra: [1, 1, 1, 0])
        }
        let cells = try #require(a.differenceCells(from: b, cellSize: 128))

        #expect(cells.count == 3)
        #expect(cells[0] == Framebuffer.DifferenceCell(rect: PixelRect(x: 0, y: 0, width: 128, height: 128), count: 2)) // most differences first
        #expect(cells.contains(Framebuffer.DifferenceCell(rect: PixelRect(x: 256, y: 0, width: 44, height: 128), count: 1)))
        #expect(cells.contains(Framebuffer.DifferenceCell(rect: PixelRect(x: 0, y: 128, width: 128, height: 72), count: 1)))
        #expect(cells.reduce(0) { $0 + $1.count } == a.difference(from: b)?.count)
    }

    @Test func identicalBuffersHaveNoCellsAndMismatchedSizesReturnNil() throws {
        let a = try Framebuffer(width: 10, height: 10)
        #expect(a.differenceCells(from: a, cellSize: 4)?.isEmpty == true)
        #expect(a.differenceCells(from: try Framebuffer(width: 11, height: 10)) == nil)
    }

    @Test func differentSizesCannotBeCompared() throws {
        #expect(try Framebuffer(width: 2, height: 2).difference(from: Framebuffer(width: 3, height: 2)) == nil)
    }
}
