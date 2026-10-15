import CoreGraphics
import Foundation
import RFBKit
import Testing
@testable import RemoteDisplay

@Suite("CursorPlacement: cursor position and size")
struct CursorPlacementTests {
    /// A 10×20 cursor with its hotspot at (2, 3).
    private let cursor = CursorImage(
        width: 10, height: 20, hotspotX: 2, hotspotY: 3, bgra: [UInt8](repeating: 255, count: 10 * 20 * 4)
    )!

    /// A 1000×500 Mac screen in a 500×250 viewport: scale 0.5 point/pixel.
    private func geometry(zoom: Double = 1) -> ViewportGeometry {
        var geometry = ViewportGeometry(remoteSize: CGSize(width: 1000, height: 500), viewSize: CGSize(width: 500, height: 250))
        if zoom != 1 { geometry.setZoom(zoom, around: CGPoint(x: 250, y: 125)) }
        return geometry
    }

    @Test func smallScreenScaleIsRaisedSoTheCursorStaysVisible() {
        // At the true scale of 0.5 point/pixel: a 20-pixel-tall cursor would be only 10 points. Raised to a minimum of 20 points = 1 point/pixel.
        #expect(CursorPlacement.pointsPerCursorPixel(for: cursor, geometry: geometry()) == 1)
    }

    @Test func hugeZoomIsCappedSoTheCursorDoesNotCoverTheScreen() {
        // Zoom 16x: true scale 8 points/pixel, but the cursor is clamped to 48 points for its long side (20 pixels) = 2.4 points/pixel.
        #expect(CursorPlacement.pointsPerCursorPixel(for: cursor, geometry: geometry(zoom: 16)) == 2.4)
    }

    @Test func midRangeScaleIsKeptTrue() {
        // 1.5 points/pixel → 30 points tall, within 20...48 so the true scale is kept.
        var geometry = ViewportGeometry(remoteSize: CGSize(width: 1000, height: 500), viewSize: CGSize(width: 1500, height: 750))
        geometry.reset()
        #expect(CursorPlacement.pointsPerCursorPixel(for: cursor, geometry: geometry) == 1.5)
    }

    @Test func hotspotLandsOnTheCentreOfThePointerPixel() {
        let geometry = geometry()
        let rect = CursorPlacement.viewRect(for: cursor, pointer: (400, 200), geometry: geometry)
        // Mac pixel (400, 200) has center (400.5, 200.5) → viewport (200.25, 100.25). Subtract hotspot (2, 3) × 1 point/pixel.
        #expect(abs(rect.minX - 198.25) < 1e-9)
        #expect(abs(rect.minY - 97.25) < 1e-9)
        #expect(rect.width == 10 && rect.height == 20)
        // Check again: the hotspot within the rectangle coincides with the pixel center.
        let hotspot = CGPoint(x: rect.minX + 2, y: rect.minY + 3)
        let expected = geometry.viewPoint(forRemote: CGPoint(x: 400.5, y: 200.5))
        #expect(abs(hotspot.x - expected.x) < 1e-9 && abs(hotspot.y - expected.y) < 1e-9)
    }

    @Test func letterboxOffsetIsRespected() {
        // The viewport is taller than the content so there are borders: content starts at y = 50.
        let geometry = ViewportGeometry(remoteSize: CGSize(width: 1000, height: 500), viewSize: CGSize(width: 500, height: 350))
        let rect = CursorPlacement.viewRect(for: cursor, pointer: (0, 0), geometry: geometry)
        #expect(abs((rect.minY + 3) - (50 + 0.25)) < 1e-9)
    }

    @Test func normalizedRectMatchesTheScreenRectConvention() {
        // The whole viewport must come out as (-1, -1, 1, 1), like the screen's `normalizedDeviceRect`.
        let full = CursorPlacement.normalizedDeviceRect(viewRect: CGRect(x: 0, y: 0, width: 500, height: 250), viewSize: CGSize(width: 500, height: 250))
        #expect(full == SIMD4<Float>(-1, -1, 1, 1))
        // Upper half of the viewport: bottom = 0, top = 1.
        let top = CursorPlacement.normalizedDeviceRect(viewRect: CGRect(x: 0, y: 0, width: 500, height: 125), viewSize: CGSize(width: 500, height: 250))
        #expect(top == SIMD4<Float>(-1, 0, 1, 1))
        #expect(geometry().normalizedDeviceRect == SIMD4<Float>(-1, -1, 1, 1))
    }
}
