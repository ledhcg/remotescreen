import Foundation
import RFBKit
import Testing
@testable import RemoteDisplay

@Suite struct CursorStyleTests {
    private func alpha(_ image: CursorImage, x: Int, y: Int) -> UInt8 { image.bgra[(y * image.width + x) * 4 + 3] }

    @Test func macStyleKeepsTheMacCursor() {
        #expect(CursorStyle.mac.replacement(for: .defaultArrow) == nil)
        #expect(CursorStyle.mac.artwork(.onScreen) == nil)
    }

    /// A blank picture of `width`×`height` with its hotspot at (`x`, `y`): only the size and hotspot matter here.
    private func macCursor(_ width: Int, _ height: Int, hotspot x: Int, _ y: Int) throws -> CursorImage {
        try #require(CursorImage(width: width, height: height, hotspotX: x, hotspotY: y, bgra: [UInt8](repeating: 255, count: width * height * 4)))
    }

    @Test func onlyMacArrowsAreReplaced() throws {
        let arrows = [try macCursor(17, 23, hotspot: 4, 4), try macCursor(34, 46, hotspot: 8, 8), CursorImage.defaultArrow]
        let contextual = [
            try macCursor(9, 18, hotspot: 4, 9),    // text I-beam
            try macCursor(24, 24, hotspot: 12, 12), // resize arrows, crosshair
            try macCursor(16, 16, hotspot: 6, 1),   // pointing hand: the fingertip is not in the corner
            try macCursor(16, 16, hotspot: 8, 8),   // open or closed hand
        ]
        for style in CursorStyle.allCases where style != .mac {
            for arrow in arrows { #expect(style.replacement(for: arrow) != nil) }
            for cursor in contextual { #expect(style.replacement(for: cursor) == nil, "\(cursor.width)x\(cursor.height) @ \(cursor.hotspotX),\(cursor.hotspotY)") }
        }
    }

    @Test func aHiddenMacCursorStaysHidden() throws {
        let hidden = try #require(CursorImage(width: 0, height: 0, hotspotX: 0, hotspotY: 0, bgra: []))
        for style in CursorStyle.allCases { #expect(style.replacement(for: hidden) == nil) }
    }

    @Test(arguments: CursorStyle.allCases.filter { $0 != .mac })
    func everyArrowHasItsHotspotOnAnOpaqueTip(style: CursorStyle) throws {
        let image = try #require(style.replacement(for: .defaultArrow))
        #expect(image.scale == CursorStyle.rasterScale)
        #expect(image.width == Int(CursorStyle.canvas) * image.scale && image.height == image.width)
        #expect(alpha(image, x: image.hotspotX + 1, y: image.hotspotY + 1) > 200)
        // The corner away from every decoration and the arrow is clear.
        #expect(alpha(image, x: image.width - 1, y: image.height - 1) == 0)
    }

    @Test func outlinedArrowsAreWhiteInsideOnScreenAndClearInTheMenu() throws {
        let scale = CursorStyle.rasterScale
        // A point well inside the dart, between the tip and the notch.
        let x = (Int(CursorStyle.tip.x) + 6) * scale, y = (Int(CursorStyle.tip.y) + 5) * scale
        let onScreen = try #require(CursorStyle.outlinedArrow.artwork(.onScreen))
        let index = (y * onScreen.width + x) * 4
        #expect(Array(onScreen.bgra[index..<index + 4]) == [255, 255, 255, 255])
        let template = try #require(CursorStyle.outlinedArrow.artwork(.template))
        #expect(alpha(template, x: x, y: y) == 0)
        let filled = try #require(CursorStyle.filledArrow.artwork(.template))
        #expect(alpha(filled, x: x, y: y) == 255)
    }

    @Test func decorationsDrawAboveTheTip() throws {
        let scale = CursorStyle.rasterScale
        // A patch straight up from the tip, where rays, dots and rings sit and the arrow never goes (wide enough to catch a dash, not a gap).
        let x = Int(CursorStyle.tip.x) * scale, y = Int((CursorStyle.tip.y - 5.4) * Double(scale))
        for style in CursorStyle.allCases where style.decoration != .none {
            let image = try #require(style.artwork(.template))
            let patch = (max(0, y - 2 * scale)...y + 2 * scale).flatMap { row in
                (x - 2 * scale...x + 2 * scale).map { alpha(image, x: $0, y: row) }
            }
            #expect(patch.contains { $0 > 0 }, "\(style)")
        }
        let plain = try #require(CursorStyle.filledArrow.artwork(.template))
        #expect(alpha(plain, x: x, y: y) == 0)
    }

    @Test func pointerPathsStartAtTheTip() throws {
        #expect(CursorStyle.mac.pointerPath == nil)
        let filled = try #require(CursorStyle.filledArrow.pointerPath)
        // The tip is the hotspot: just inside it is ink, and the arrow reaches down-right from there.
        #expect(filled.contains(CGPoint(x: 0.5, y: 0.5)))
        #expect(filled.contains(CGPoint(x: 6, y: 5)))
        #expect(!filled.contains(CGPoint(x: -3, y: 6)))
        // Outlined: the inside is a hole, so the system pointer colour only fills the outline.
        let outlined = try #require(CursorStyle.outlinedArrow.pointerPath)
        #expect(!outlined.contains(CGPoint(x: 6, y: 5)))
        #expect(outlined.contains(CGPoint(x: 0.5, y: 0.5)))
        // Decorations sit up and left of the tip.
        for style in CursorStyle.allCases where style.decoration != .none {
            let path = try #require(style.pointerPath)
            #expect(path.boundingBox.minY < -4, "\(style)")
        }
    }

    @Test func aHighDensityCursorIsPlacedAtItsOwnSize() throws {
        let image = try #require(CursorStyle.filledArrow.replacement(for: .defaultArrow))
        let geometry = ViewportGeometry(remoteSize: CGSize(width: 2000, height: 1000), viewSize: CGSize(width: 1000, height: 500))
        let rect = CursorPlacement.viewRect(for: image, pointer: (x: 1000, y: 500), geometry: geometry)
        // 28 cursor pixels at scale 0.5 is 14 points, raised to the 20-point minimum.
        #expect(abs(rect.width - 20) < 0.001)
        // The tip lands on the pointer's pixel centre.
        let hotspot = geometry.viewPoint(forRemote: CGPoint(x: 1000.5, y: 500.5))
        #expect(abs(rect.minX + Double(image.hotspotX) * rect.width / Double(image.width) - hotspot.x) < 0.001)
    }
}
