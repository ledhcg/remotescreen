import CoreGraphics
import Foundation
import RFBKit
import Synchronization

/// The look of the pointer drawn over the Mac screen: the Mac's own cursor, or one of Screon's arrows.
///
/// Screon's arrows are drawn here as vector shapes (no image assets) and rasterized at `rasterScale` so they stay sharp at the
/// largest size `CursorPlacement` shows. Each is an arrow body, filled or outlined, plus an optional decoration around the tip.
public enum CursorStyle: String, CaseIterable, Sendable {
    /// Whatever the Mac shows: arrow, I-beam, resize, pointing hand.
    case mac
    case filledArrow
    case outlinedArrow
    case filledArrowRays
    case outlinedArrowDots
    case filledArrowDashedRing
    case outlinedArrowDottedRing

    public static let `default` = CursorStyle.mac

    /// The arrow body.
    public enum Body: Sendable { case filled, outlined }

    /// What is drawn around the tip.
    public enum Decoration: Sendable { case none, rays, dots, dashedRing, dottedRing }

    /// `nil` for `.mac`.
    public var body: Body? {
        switch self {
        case .mac: nil
        case .filledArrow, .filledArrowRays, .filledArrowDashedRing: .filled
        case .outlinedArrow, .outlinedArrowDots, .outlinedArrowDottedRing: .outlined
        }
    }

    public var decoration: Decoration {
        switch self {
        case .mac, .filledArrow, .outlinedArrow: .none
        case .filledArrowRays: .rays
        case .outlinedArrowDots: .dots
        case .filledArrowDashedRing: .dashedRing
        case .outlinedArrowDottedRing: .dottedRing
        }
    }

    /// The cursor to draw while the Mac shows `macCursor`. `nil` keeps the Mac's cursor.
    ///
    /// An empty Mac cursor (the Mac hides the pointer, for example while typing or playing a video) stays hidden whatever the style.
    public func replacement(for macCursor: CursorImage) -> CursorImage? {
        guard self != .mac, !macCursor.isEmpty, Self.replacesMacCursor(macCursor) else { return nil }
        return cursorImage
    }

    /// Whether a chosen style replaces this (visible) Mac cursor: only the arrows. The cursors that tell what a click will do (the
    /// text I-beam, resize arrows, the pointing hand over a link, the crosshair) stay the Mac's own, or the user would lose them.
    ///
    /// RFB sends a cursor as a picture with no name, so the kind is told by its hotspot: an arrow clicks at its tip in the top-left
    /// corner of the picture, while the others click at their centre or, for the hand, at a fingertip well inside the picture.
    static func replacesMacCursor(_ macCursor: CursorImage) -> Bool {
        guard macCursor.width > 0, macCursor.height > 0 else { return false }
        let x = Double(macCursor.hotspotX) / Double(macCursor.width)
        let y = Double(macCursor.hotspotY) / Double(macCursor.height)
        return x < arrowHotspotLimit && y < arrowHotspotLimit
    }

    /// An arrow's hotspot lies within this fraction of the picture from its top-left corner (the Mac's arrow: about 0.2).
    static let arrowHotspotLimit = 0.3

    // MARK: - Artwork

    /// Side of the square canvas, in cursor pixels. The tip sits at `tip`, leaving room for decorations above and left of it.
    static let canvas = 28.0
    static let tip = CGPoint(x: 8, y: 8)
    /// Image pixels per cursor pixel: 28 × 6 = 168 pixels, sharp at 48 points on a 3× screen.
    public static let rasterScale = 6

    /// The arrow outline, relative to the tip: a dart pointing up-left with a notch at the back.
    static func arrowPath() -> CGPath {
        let path = CGMutablePath()
        path.move(to: point(0, 0))
        path.addLine(to: point(16.5, 6.5))
        path.addLine(to: point(9, 9))
        path.addLine(to: point(6.5, 16.5))
        path.closeSubpath()
        return path
    }

    /// The decoration as strokes (`width`, `dash`) around the tip. Empty for `.none`.
    static func decorationStrokes(_ decoration: Decoration) -> [(path: CGPath, width: Double, dash: [Double])] {
        switch decoration {
        case .none:
            return []
        case .rays:
            let path = CGMutablePath()
            for degrees in [-55.0, -95, -135, -175, 150] {
                path.move(to: polar(radius: 2.6, degrees: degrees))
                path.addLine(to: polar(radius: 6.2, degrees: degrees))
            }
            return [(path, 1.25, [])]
        case .dots:
            let path = CGMutablePath()
            for (degrees, radius, diameter) in [(-55.0, 4.8, 1.5), (-100, 5.6, 2.0), (-140, 5.6, 2.0), (-180, 5.6, 2.0)] {
                let center = polar(radius: radius, degrees: degrees)
                path.addEllipse(in: CGRect(x: center.x - diameter / 2, y: center.y - diameter / 2, width: diameter, height: diameter))
            }
            return [(path, 0, [])] // filled, not stroked
        case .dashedRing:
            return [(ringPath(), 1.4, [0.5, 2.3])] // round caps lengthen each dash by the line width
        case .dottedRing:
            return [(ringPath(), 1.5, [0, 2.1])]
        }
    }

    /// A ring arc around the tip, from lower left over the top to upper right, away from the arrow.
    private static func ringPath() -> CGPath {
        let path = CGMutablePath()
        path.addArc(center: tip, radius: 5.4, startAngle: radians(160), endAngle: radians(-40), clockwise: false)
        return path
    }

    private static func point(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: tip.x + x, y: tip.y + y) }

    /// y grows downward, so -90° is straight up.
    private static func polar(radius: Double, degrees: Double) -> CGPoint {
        CGPoint(x: tip.x + radius * cos(radians(degrees)), y: tip.y + radius * sin(radians(degrees)))
    }

    private static func radians(_ degrees: Double) -> Double { degrees * .pi / 180 }

    /// How the artwork is painted.
    public enum Rendering: Sendable {
        /// On the Mac screen: black ink with a white halo (and a white inside for outlined arrows), so it shows on dark and light content.
        case onScreen
        /// A preview for menus: ink only, transparent inside, so the system can tint it like the text next to it.
        case template
    }

    /// The style rasterized as premultiplied BGRA. `nil` for `.mac`.
    public func artwork(_ rendering: Rendering, scale: Int = CursorStyle.rasterScale) -> CursorImage? {
        guard let body else { return nil }
        let side = Int(Self.canvas) * scale
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            ) else { return false }
            // y down, in cursor pixels.
            context.translateBy(x: 0, y: CGFloat(side))
            context.scaleBy(x: CGFloat(scale), y: -CGFloat(scale))
            Self.paint(body: body, decoration: decoration, rendering: rendering, in: context)
            return true
        }
        guard drawn else { return nil }
        let hotspot = Int(Self.tip.x) * scale
        return CursorImage(width: side, height: side, hotspotX: hotspot, hotspotY: hotspot, bgra: pixels, scale: scale)
    }

    private static func paint(body: Body, decoration: Decoration, rendering: Rendering, in context: CGContext) {
        let ink = CGColor(gray: 0.06, alpha: 1)
        let paper = CGColor(gray: 1, alpha: 1)
        let arrow = arrowPath()
        let strokes = decorationStrokes(decoration)
        context.setLineJoin(.round)
        context.setLineCap(.round)

        if rendering == .onScreen {
            // Halo first: everything drawn again in white, wider, underneath.
            context.setStrokeColor(paper)
            context.setFillColor(paper)
            context.addPath(arrow)
            context.setLineWidth(body == .filled ? 3 : 3.6)
            context.drawPath(using: .fillStroke)
            for stroke in strokes {
                context.setLineDash(phase: 0, lengths: stroke.dash.map { CGFloat($0) })
                context.addPath(stroke.path)
                if stroke.width == 0 {
                    context.setLineWidth(1.6)
                    context.drawPath(using: .fillStroke)
                } else {
                    context.setLineWidth(stroke.width + 1.8)
                    context.strokePath()
                }
            }
            context.setLineDash(phase: 0, lengths: [])
        }

        context.setStrokeColor(ink)
        context.setFillColor(ink)
        context.addPath(arrow)
        switch body {
        case .filled:
            context.setLineWidth(1.2) // softens the corners
            context.drawPath(using: .fillStroke)
        case .outlined:
            context.setLineWidth(1.6)
            context.strokePath()
        }
        for stroke in strokes {
            context.addPath(stroke.path)
            if stroke.width == 0 {
                context.fillPath()
            } else {
                context.setLineDash(phase: 0, lengths: stroke.dash.map { CGFloat($0) })
                context.setLineWidth(stroke.width)
                context.strokePath()
                context.setLineDash(phase: 0, lengths: [])
            }
        }
    }

    /// The style as one filled shape with the tip at (0, 0), one unit per point: the ink of the artwork (outlines and decorations
    /// turned into filled areas). For an iPadOS custom pointer shape, which the system fills with the pointer colour. `nil` for `.mac`.
    public var pointerPath: CGPath? {
        guard let body else { return nil }
        let arrow = Self.arrowPath()
        var shape = switch body {
        case .filled: arrow.union(arrow.copy(strokingWithWidth: 1.2, lineCap: .round, lineJoin: .round, miterLimit: 10))
        case .outlined: arrow.copy(strokingWithWidth: 1.6, lineCap: .round, lineJoin: .round, miterLimit: 10)
        }
        for stroke in Self.decorationStrokes(decoration) {
            if stroke.width == 0 {
                shape = shape.union(stroke.path)
                continue
            }
            let dashed = stroke.dash.isEmpty
                ? stroke.path
                : stroke.path.copy(dashingWithPhase: 0, lengths: stroke.dash.map { CGFloat($0) })
            shape = shape.union(dashed.copy(strokingWithWidth: stroke.width, lineCap: .round, lineJoin: .round, miterLimit: 10))
        }
        var toTip = CGAffineTransform(translationX: -Self.tip.x, y: -Self.tip.y)
        return shape.copy(using: &toTip)
    }

    /// The on-screen cursor, rasterized once per style.
    private var cursorImage: CursorImage? {
        Self.cache.withLock { cache in
            if let image = cache[self] { return image }
            let image = artwork(.onScreen)
            cache[self] = image
            return image
        }
    }

    private static let cache = Mutex<[CursorStyle: CursorImage]>([:])
}
