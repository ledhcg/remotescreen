import CoreGraphics
import Foundation
import InputKit

/// How the remote screen is placed in the viewport: zoom, pan and coordinate conversion.
///
/// Pure math with no UIKit or Metal dependency, so it can be tested on macOS.
/// Viewport units are **points** (origin at top left, y pointing down). Remote screen units are Mac pixels.
public struct ViewportGeometry: Equatable, Sendable {
    public enum ScaleMode: Equatable, Sendable {
        /// Fits the viewport exactly, keeping the aspect ratio, with black borders if the ratios differ.
        case fit
        /// Fills the viewport, keeping the aspect ratio and cropping the excess.
        case fill
        /// 1 Mac pixel equals 1 device pixel (`screenScale` is device pixels per point).
        case pixelPerfect(screenScale: Double)
        /// 1 Mac pixel equals 1 point.
        case points
    }

    /// Zoom range the user is allowed, applied on top of the base scale of `scaleMode`.
    public static let zoomRange: ClosedRange<Double> = 1...16

    public var remoteSize: CGSize
    public var viewSize: CGSize
    public var scaleMode: ScaleMode
    public private(set) var zoom: Double = 1
    /// Offset of the screen from the centered position, in points. Always clamped within `contentRect`.
    public private(set) var pan: CGPoint = .zero
    /// Crop requested with `setSourceRect`; `nil` shows the whole remote surface.
    private var requestedSourceRect: CGRect?

    public init(remoteSize: CGSize, viewSize: CGSize, scaleMode: ScaleMode = .fit) {
        self.remoteSize = remoteSize
        self.viewSize = viewSize
        self.scaleMode = scaleMode
    }

    // MARK: - Source rectangle

    /// Part of the remote surface that is shown, in remote pixels. The whole surface by default. Cropping (one window out of a bigger
    /// surface) and zoom/pan share one transform: the fit/fill scale, `contentRect` and every mapping below describe this rectangle.
    /// A request that does not intersect the surface falls back to the whole surface; one that sticks out is clipped.
    public var sourceRect: CGRect {
        let whole = CGRect(origin: .zero, size: remoteSize)
        guard let requested = requestedSourceRect else { return whole }
        let clipped = requested.intersection(whole)
        return (clipped.isNull || clipped.width <= 0 || clipped.height <= 0) ? whole : clipped
    }

    /// Sets the part of the remote surface to show, or `nil` for all of it. Zoom is kept, pan is re-clamped.
    public mutating func setSourceRect(_ rect: CGRect?) {
        requestedSourceRect = rect
        normalisePan()
    }

    /// The source rectangle as `(u0, v0, u1, v1)` of the remote surface (v = 0 at the top), for the shader.
    public var sourceUVRect: SIMD4<Float> {
        guard remoteSize.width > 0, remoteSize.height > 0 else { return SIMD4(0, 0, 1, 1) }
        let source = sourceRect
        return SIMD4(
            Float(source.minX / remoteSize.width), Float(source.minY / remoteSize.height),
            Float(source.maxX / remoteSize.width), Float(source.maxY / remoteSize.height)
        )
    }

    // MARK: - Scale and displayed rectangle

    private var isDegenerate: Bool {
        remoteSize.width <= 0 || remoteSize.height <= 0 || viewSize.width <= 0 || viewSize.height <= 0
    }

    /// Points per Mac pixel when `zoom == 1`.
    public var baseScale: Double {
        guard !isDegenerate else { return 1 }
        let source = sourceRect.size
        let widthRatio = viewSize.width / source.width
        let heightRatio = viewSize.height / source.height
        switch scaleMode {
        case .fit: return min(widthRatio, heightRatio)
        case .fill: return max(widthRatio, heightRatio)
        case .pixelPerfect(let screenScale): return screenScale > 0 ? 1 / screenScale : 1
        case .points: return 1
        }
    }

    /// Points per Mac pixel after zooming.
    public var scale: Double { baseScale * zoom }

    /// Rectangle the shown part of the remote screen (`sourceRect`) occupies in the viewport (can be larger than the viewport when zoomed).
    public var contentRect: CGRect {
        let size = scaledSourceSize
        let centered = CGPoint(x: (viewSize.width - size.width) / 2, y: (viewSize.height - size.height) / 2)
        let offset = Self.clamp(pan, content: size, view: viewSize)
        return CGRect(origin: CGPoint(x: centered.x + offset.x, y: centered.y + offset.y), size: size)
    }

    private var scaledSourceSize: CGSize {
        let source = sourceRect.size
        return CGSize(width: source.width * scale, height: source.height * scale)
    }

    /// Clamps the offset: if the screen is smaller than the viewport along an axis, keep it centered on that axis; if larger,
    /// do not let panning reveal empty space past the edge.
    private static func clamp(_ pan: CGPoint, content: CGSize, view: CGSize) -> CGPoint {
        func axis(_ value: Double, content: Double, view: Double) -> Double {
            let overflow = content - view
            guard overflow > 0 else { return 0 }
            return min(max(value, -overflow / 2), overflow / 2)
        }
        return CGPoint(x: axis(pan.x, content: content.width, view: view.width),
                       y: axis(pan.y, content: content.height, view: view.height))
    }

    // MARK: - Operations

    /// Pans the content by `delta` (points).
    public mutating func pan(by delta: CGPoint) {
        pan = CGPoint(x: contentOffset.x + delta.x, y: contentOffset.y + delta.y)
        normalisePan()
    }

    /// Sets an absolute zoom, keeping the `focus` point (in the viewport) fixed on the remote screen.
    public mutating func setZoom(_ value: Double, around focus: CGPoint) {
        let anchor = remotePoint(forView: focus)
        zoom = min(max(value, Self.zoomRange.lowerBound), Self.zoomRange.upperBound)

        let size = scaledSourceSize
        let source = sourceRect
        let centered = CGPoint(x: (viewSize.width - size.width) / 2, y: (viewSize.height - size.height) / 2)
        let desiredOrigin = CGPoint(x: focus.x - (anchor.x - source.minX) * scale, y: focus.y - (anchor.y - source.minY) * scale)
        pan = CGPoint(x: desiredOrigin.x - centered.x, y: desiredOrigin.y - centered.y)
        normalisePan()
    }

    /// Multiplies the zoom by `factor` (for the pinch gesture), keeping `focus` fixed.
    public mutating func zoom(by factor: Double, around focus: CGPoint) {
        setZoom(zoom * factor, around: focus)
    }

    /// Back to the base zoom, centered.
    public mutating func reset() {
        zoom = 1
        pan = .zero
    }

    /// Updates the viewport size (rotation, window change), keeping the pan valid.
    public mutating func updateViewSize(_ size: CGSize) {
        viewSize = size
        normalisePan()
    }

    /// Updates the remote screen size (the server changed resolution).
    public mutating func updateRemoteSize(_ size: CGSize) {
        remoteSize = size
        normalisePan()
    }

    private var contentOffset: CGPoint {
        return Self.clamp(pan, content: scaledSourceSize, view: viewSize)
    }

    private mutating func normalisePan() {
        pan = contentOffset
    }

    // MARK: - Coordinate conversion

    /// Point in the viewport → (real) point on the remote screen. May fall outside the screen if the touch is on the black border.
    public func remotePoint(forView point: CGPoint) -> CGPoint {
        let rect = contentRect
        let scale = self.scale
        let source = sourceRect
        return CGPoint(x: source.minX + (point.x - rect.minX) / scale, y: source.minY + (point.y - rect.minY) / scale)
    }

    /// Point on the remote screen → point in the viewport.
    public func viewPoint(forRemote point: CGPoint) -> CGPoint {
        let rect = contentRect
        let source = sourceRect
        return CGPoint(x: rect.minX + (point.x - source.minX) * scale, y: rect.minY + (point.y - source.minY) * scale)
    }

    /// Mac pixel under a point in the viewport.
    /// - Parameter clamped: `true` clamps to the screen edge when the point is outside (suits trackpad mode); `false` returns `nil`
    /// when the point is outside (suits direct touch, where touching the black border should control nothing).
    public func remotePixel(forView point: CGPoint, clamped: Bool) -> (x: Int, y: Int)? {
        guard !isDegenerate else { return nil }
        let remote = remotePoint(forView: point)
        let x = Int(remote.x.rounded(.down))
        let y = Int(remote.y.rounded(.down))
        let source = sourceRect
        let minX = Int(source.minX.rounded(.down))
        let minY = Int(source.minY.rounded(.down))
        let maxX = Int(source.maxX.rounded(.up)) - 1
        let maxY = Int(source.maxY.rounded(.up)) - 1
        if (minX...maxX).contains(x) && (minY...maxY).contains(y) { return (x, y) }
        guard clamped else { return nil }
        return (min(max(x, minX), maxX), min(max(y, minY), maxY))
    }

    // MARK: - Cho GPU

    /// Rectangle of the shown part of the remote screen (`sourceRect`) in the device's normalized coordinates (-1...1, y axis pointing UP):
    /// `(left, bottom, right, top)`.
    public var normalizedDeviceRect: SIMD4<Float> {
        guard viewSize.width > 0, viewSize.height > 0 else { return SIMD4(-1, -1, 1, 1) }
        let rect = contentRect
        return SIMD4(
            Float(2 * rect.minX / viewSize.width - 1),
            Float(1 - 2 * rect.maxY / viewSize.height),
            Float(2 * rect.maxX / viewSize.width - 1),
            Float(1 - 2 * rect.minY / viewSize.height)
        )
    }
}

extension ViewportGeometry: RemoteCoordinateSpace {
    public var pointsPerRemotePixel: Double { scale }
}
