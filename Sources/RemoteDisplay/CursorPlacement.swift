import CoreGraphics
import Foundation
import RFBKit

/// Places the Mac's cursor image on the viewport: position from the hotspot, and a size that is easy to see.
///
/// Pure math with no Metal dependency, so it can be tested without a GPU.
public enum CursorPlacement {
    /// Largest dimension of the cursor when displayed, in points, kept within this range regardless of zoom.
    ///
    /// Drawn to scale with the Mac screen, on an iPhone (a 2048-pixel Mac squeezed into ~390 points) a 32-pixel cursor would be only
    /// about 6 points, nearly invisible, and at 16x zoom it would exceed 500 points. Clamping keeps it clearly visible at all times
    /// without hiding content.
    public static let displayPointRange: ClosedRange<Double> = 20...48

    /// Points per pixel of the cursor image (an image pixel, so a cursor drawn at `scale` 6 gets a sixth of the points per pixel).
    public static func pointsPerCursorPixel(for cursor: CursorImage, geometry: ViewportGeometry) -> Double {
        let density = Double(max(cursor.scale, 1))
        let longest = Double(max(cursor.width, cursor.height)) / density
        guard longest > 0 else { return geometry.scale / density }
        return min(max(geometry.scale, displayPointRange.lowerBound / longest), displayPointRange.upperBound / longest) / density
    }

    /// Cursor rectangle in the viewport (points, origin at top left) when the cursor is at Mac pixel `pointer`.
    /// The image's hotspot coincides with the center of that pixel.
    public static func viewRect(
        for cursor: CursorImage, pointer: (x: Int, y: Int), geometry: ViewportGeometry
    ) -> CGRect {
        let unit = pointsPerCursorPixel(for: cursor, geometry: geometry)
        let hotspotInView = geometry.viewPoint(forRemote: CGPoint(x: Double(pointer.x) + 0.5, y: Double(pointer.y) + 0.5))
        return CGRect(
            x: hotspotInView.x - Double(cursor.hotspotX) * unit,
            y: hotspotInView.y - Double(cursor.hotspotY) * unit,
            width: Double(cursor.width) * unit,
            height: Double(cursor.height) * unit
        )
    }

    /// The same rectangle in normalized device coordinates, `(left, bottom, right, top)`, with the y axis pointing UP,
    /// matching the layout of `ViewportGeometry.normalizedDeviceRect`.
    public static func normalizedDeviceRect(viewRect rect: CGRect, viewSize: CGSize) -> SIMD4<Float> {
        guard viewSize.width > 0, viewSize.height > 0 else { return SIMD4(0, 0, 0, 0) }
        return SIMD4(
            Float(2 * rect.minX / viewSize.width - 1),
            Float(1 - 2 * rect.maxY / viewSize.height),
            Float(2 * rect.maxX / viewSize.width - 1),
            Float(1 - 2 * rect.minY / viewSize.height)
        )
    }
}
