import CoreGraphics
import Foundation
import InputKit
import LinkProtocol

/// How the window's picture is laid into the scene.
public enum WindowFitMode: Sendable, Equatable {
    /// The whole window is visible (letterboxed): the scale is the smaller of the two ratios.
    case fit
    /// The window covers the whole view (cropped): the scale is the larger of the two ratios.
    case fill
    /// One Mac point is one view point.
    case actual
}

/// Maps between the scene's view points and the window's own coordinates, which are Mac points relative to the window's content
/// origin (the unit of every `input.*` message). All values are `Double`; nothing is rounded except in the `RemoteCoordinateSpace`
/// conformance, which InputKit's touch mapper needs in whole numbers.
///
/// The picture is centred in the view, scaled by `baseScale * zoom`, then shifted by `pan`. When the picture is larger than the
/// view on an axis the shift is limited so no empty border shows; when smaller, it stays centred.
///
/// `backingScale` (device pixels per Mac point, 1 or 2 for Retina) does not change the mapping: it sizes the stream
/// (`pixelSize`) so view coordinates stay in points on both sides.
public struct WindowCoordinateSpace: RemoteCoordinateSpace, Sendable, Equatable {
    public static let zoomRange: ClosedRange<Double> = 0.1...16

    /// Window size in Mac points.
    public var windowSize: CGSize
    public var backingScale: Double
    /// Size of the view that shows the window, in view points.
    public var viewSize: CGSize
    public var fitMode: WindowFitMode
    /// Rectangles of transient surfaces (menus, popovers) in window coordinates. They may extend outside the window.
    public var surfaces: [CGRect]

    public private(set) var zoom: Double
    /// Shift of the picture from its centred position, in view points (use `effectivePan` for the value after limiting).
    public private(set) var pan: CGPoint

    public init(
        windowSize: CGSize, backingScale: Double = 1, viewSize: CGSize, fitMode: WindowFitMode = .fit,
        zoom: Double = 1, pan: CGPoint = .zero, surfaces: [CGRect] = []
    ) {
        self.windowSize = windowSize
        self.backingScale = backingScale
        self.viewSize = viewSize
        self.fitMode = fitMode
        self.surfaces = surfaces
        self.zoom = Self.clampZoom(zoom)
        self.pan = pan
    }

    // MARK: Geometry

    /// False when a size is not finite and positive: nothing can be mapped.
    public var isValid: Bool {
        Self.isPositive(windowSize.width) && Self.isPositive(windowSize.height)
            && Self.isPositive(viewSize.width) && Self.isPositive(viewSize.height)
    }

    /// View points per Mac point before zoom.
    public var baseScale: Double {
        guard isValid else { return 1 }
        let sx = viewSize.width / windowSize.width, sy = viewSize.height / windowSize.height
        switch fitMode {
        case .fit: return min(sx, sy)
        case .fill: return max(sx, sy)
        case .actual: return 1
        }
    }

    /// View points per Mac point.
    public var scale: Double { baseScale * zoom }

    public var contentSize: CGSize { CGSize(width: windowSize.width * scale, height: windowSize.height * scale) }

    public var isZoomed: Bool { zoom > 1.0001 || contentSize.width > viewSize.width + 0.5 || contentSize.height > viewSize.height + 0.5 }

    /// The pan after limiting to what keeps the view covered.
    public var effectivePan: CGPoint {
        let content = contentSize
        func limit(_ pan: Double, _ content: Double, _ view: Double) -> Double {
            guard content > view, pan.isFinite else { return 0 }
            let bound = (content - view) / 2
            return min(max(pan, -bound), bound)
        }
        return CGPoint(x: limit(pan.x, content.width, viewSize.width), y: limit(pan.y, content.height, viewSize.height))
    }

    /// Where the window's top-left corner is in the view.
    public var contentOrigin: CGPoint {
        let content = contentSize, shift = effectivePan
        return CGPoint(x: (viewSize.width - content.width) / 2 + shift.x, y: (viewSize.height - content.height) / 2 + shift.y)
    }

    /// The window rectangle in view points.
    public var contentRect: CGRect { CGRect(origin: contentOrigin, size: contentSize) }

    /// The stream size to ask for, in device pixels.
    public var pixelSize: CGSize {
        CGSize(width: (windowSize.width * backingScale).rounded(), height: (windowSize.height * backingScale).rounded())
    }

    // MARK: Zoom and pan

    public mutating func setZoom(_ value: Double) { zoom = Self.clampZoom(value); pan = effectivePan }

    /// Sets the zoom keeping the window point under `anchor` (a view point, for example the pinch centre) where it is.
    public mutating func setZoom(_ value: Double, anchoredAtView anchor: CGPoint) {
        guard isValid, anchor.x.isFinite, anchor.y.isFinite else { return setZoom(value) }
        let before = windowPoint(forView: anchor)
        zoom = Self.clampZoom(value)
        let content = contentSize
        pan = CGPoint(
            x: anchor.x - before.x * scale - (viewSize.width - content.width) / 2,
            y: anchor.y - before.y * scale - (viewSize.height - content.height) / 2
        )
        pan = effectivePan
    }

    public mutating func pan(by delta: CGPoint) {
        let current = effectivePan
        pan = CGPoint(x: current.x + delta.x, y: current.y + delta.y)
        pan = effectivePan
    }

    public mutating func resetZoom() { zoom = 1; pan = .zero }

    // MARK: Mapping

    /// View point to window point, without any bounds check.
    public func windowPoint(forView point: CGPoint) -> CGPoint {
        let origin = contentOrigin, s = scale
        return CGPoint(x: (point.x - origin.x) / s, y: (point.y - origin.y) / s)
    }

    /// Window point to view point.
    public func viewPoint(forWindow point: CGPoint) -> CGPoint {
        let origin = contentOrigin, s = scale
        return CGPoint(x: origin.x + point.x * s, y: origin.y + point.y * s)
    }

    private var windowBounds: CGRect { CGRect(origin: .zero, size: windowSize) }

    /// True when the window point is inside the window or inside one of its transient surfaces.
    public func contains(windowPoint point: CGPoint) -> Bool {
        guard isValid, point.x.isFinite, point.y.isFinite else { return false }
        return containsInclusive(windowBounds, point) || surfaces.contains { containsInclusive($0, point) }
    }

    /// Rectangles include their far edges so a pointer on the last pixel line still hits.
    private func containsInclusive(_ rect: CGRect, _ point: CGPoint) -> Bool {
        point.x >= rect.minX && point.x <= rect.maxX && point.y >= rect.minY && point.y <= rect.maxY
    }

    /// Clamps a window point into the window rectangle. A point inside a surface is returned unchanged.
    public func clamped(windowPoint point: CGPoint) -> CGPoint {
        guard isValid else { return .zero }
        let x = point.x.isFinite ? point.x : (point.x > 0 ? windowSize.width : 0)
        let y = point.y.isFinite ? point.y : (point.y > 0 ? windowSize.height : 0)
        let p = CGPoint(x: x, y: y)
        if surfaces.contains(where: { containsInclusive($0, p) }) { return p }
        return CGPoint(x: min(max(x, 0), windowSize.width), y: min(max(y, 0), windowSize.height))
    }

    /// The window point under a view point for pointer events: `nil` outside the window and its surfaces unless `clamped`.
    public func windowPoint(forView point: CGPoint, clamped: Bool) -> LinkPoint? {
        guard isValid, point.x.isFinite, point.y.isFinite else { return nil }
        let p = windowPoint(forView: point)
        if contains(windowPoint: p) { return LinkPoint(x: p.x, y: p.y) }
        guard clamped else { return nil }
        let c = self.clamped(windowPoint: p)
        return LinkPoint(x: c.x, y: c.y)
    }

    // MARK: RemoteCoordinateSpace (whole Mac points)

    public var remoteSize: CGSize { windowSize }

    /// View points per Mac point at the current zoom.
    public var pointsPerRemotePixel: Double { scale }

    public func remotePixel(forView point: CGPoint, clamped: Bool) -> (x: Int, y: Int)? {
        guard let mapped = windowPoint(forView: point, clamped: clamped) else { return nil }
        var x = mapped.x.rounded(), y = mapped.y.rounded()
        if clamped, !surfaces.contains(where: { containsInclusive($0, CGPoint(x: mapped.x, y: mapped.y)) }) {
            // Rounding the far edge must not produce a coordinate outside the window.
            x = min(x, max(0, windowSize.width.rounded(.up) - 1))
            y = min(y, max(0, windowSize.height.rounded(.up) - 1))
        }
        return (Int(x), Int(y))
    }

    // MARK: Helpers

    private static func isPositive(_ value: CGFloat) -> Bool { value.isFinite && value > 0 }

    private static func clampZoom(_ value: Double) -> Double {
        guard value.isFinite else { return 1 }
        return min(max(value, zoomRange.lowerBound), zoomRange.upperBound)
    }
}
