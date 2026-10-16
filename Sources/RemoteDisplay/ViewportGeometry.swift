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
    /// Margins of the viewport the system may cover (status bar, notch or Dynamic Island, home indicator, rounded display corners).
    /// `.fit` keeps the whole screen inside them; larger content can be dragged until its edges reach them, so nothing stays hidden.
    public private(set) var insets: ViewportInsets = .zero
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
        switch scaleMode {
        case .fit:
            let safe = safeSize
            return min(safe.width / source.width, safe.height / source.height)
        case .fill: return max(viewSize.width / source.width, viewSize.height / source.height)
        case .pixelPerfect(let screenScale): return screenScale > 0 ? 1 / screenScale : 1
        case .points: return 1
        }
    }

    /// Points per Mac pixel after zooming.
    public var scale: Double { baseScale * zoom }

    /// Rectangle the shown part of the remote screen (`sourceRect`) occupies in the viewport (can be larger than the viewport when zoomed).
    public var contentRect: CGRect {
        let size = scaledSourceSize
        return CGRect(
            x: Self.origin(pan: pan.x, content: size.width, view: viewSize.width, leading: insets.left, trailing: insets.right),
            y: Self.origin(pan: pan.y, content: size.height, view: viewSize.height, leading: insets.top, trailing: insets.bottom),
            width: size.width, height: size.height
        )
    }

    private var scaledSourceSize: CGSize {
        let source = sourceRect.size
        return CGSize(width: source.width * scale, height: source.height * scale)
    }

    /// The viewport without its insets; the whole viewport if the insets leave nothing.
    private var safeSize: CGSize {
        let width = viewSize.width - insets.left - insets.right
        let height = viewSize.height - insets.top - insets.bottom
        return width > 0 && height > 0 ? CGSize(width: width, height: height) : viewSize
    }

    /// Where the content starts along one axis, for an offset `pan` from where it rests.
    /// - Content that fits between the insets is centred between them and does not move.
    /// - Larger content rests centred on the whole axis and moves until its edges reach the insets: no empty space opens past a
    ///   visible edge, yet the part under a status bar, notch or rounded corner can always be dragged into view.
    private static func origin(pan: Double, content: Double, view: Double, leading: Double, trailing: Double) -> Double {
        let safe = view - leading - trailing
        // Insets that cover everything (or a view not laid out yet, size 0) are ignored. Only recurse when that changes something:
        // with no insets and a zero-size view this used to call itself forever (optimised into a loop, the app froze at launch).
        if safe <= 0, leading != 0 || trailing != 0 {
            return origin(pan: pan, content: content, view: view, leading: 0, trailing: 0)
        }
        if content <= safe { return leading + (safe - content) / 2 }
        let resting = (view - content) / 2
        return min(max(resting + pan, view - trailing - content), leading)
    }

    // MARK: - Operations

    /// Pans the content by `delta` (points).
    public mutating func pan(by delta: CGPoint) {
        pan = CGPoint(x: pan.x + delta.x, y: pan.y + delta.y)
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

    /// Updates the margins the system may cover (safe area, display corners), keeping the pan valid.
    public mutating func updateInsets(_ newInsets: ViewportInsets) {
        insets = newInsets
        normalisePan()
    }

    /// Updates the remote screen size (the server changed resolution).
    public mutating func updateRemoteSize(_ size: CGSize) {
        remoteSize = size
        normalisePan()
    }

    /// Stores the pan that is actually applied, so dragging back from past an edge responds at once.
    private mutating func normalisePan() {
        let rect = contentRect
        pan = CGPoint(x: rect.minX - (viewSize.width - rect.width) / 2, y: rect.minY - (viewSize.height - rect.height) / 2)
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

    // MARK: - For the GPU

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

/// Margins of a viewport in points.
public struct ViewportInsets: Equatable, Sendable {
    public var top: Double
    public var left: Double
    public var bottom: Double
    public var right: Double

    public static let zero = ViewportInsets(top: 0, left: 0, bottom: 0, right: 0)

    public init(top: Double, left: Double, bottom: Double, right: Double) {
        self.top = top
        self.left = left
        self.bottom = bottom
        self.right = right
    }

    /// Which edges of a view lie on the edges of the physical display.
    public struct DisplayEdges: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let top = DisplayEdges(rawValue: 1 << 0)
        public static let left = DisplayEdges(rawValue: 1 << 1)
        public static let bottom = DisplayEdges(rawValue: 1 << 2)
        public static let right = DisplayEdges(rawValue: 1 << 3)
        public static let all: DisplayEdges = [.top, .left, .bottom, .right]
    }

    /// Grows these insets so no corner of the content can sit under a rounded display corner of `radius` points.
    ///
    /// A corner of the view is rounded only where two of its edges lie on the display's edges. It is already clear when either inset
    /// beside it reaches `radius` (a status bar, a notch). Otherwise one of the two grows to `radius`: the axis on which the content
    /// leaves empty space anyway (`contentAspect` against the view's), so fitting the Mac screen usually costs no size at all.
    public func avoidingRoundedCorners(radius: Double, edges: DisplayEdges, viewSize: CGSize, contentAspect: Double) -> ViewportInsets {
        guard radius > 0, viewSize.width > 0, viewSize.height > 0 else { return self }
        // Wider content than the view leaves room above and below it: grow top/bottom. Taller content: grow left/right.
        let growVertical = contentAspect >= viewSize.width / viewSize.height
        var result = self
        for (vertical, horizontal) in [(DisplayEdges.top, DisplayEdges.left), (.top, .right), (.bottom, .left), (.bottom, .right)] {
            guard edges.contains(vertical), edges.contains(horizontal) else { continue }
            let verticalInset = vertical == .top ? result.top : result.bottom
            let horizontalInset = horizontal == .left ? result.left : result.right
            guard max(verticalInset, horizontalInset) < radius else { continue }
            if growVertical {
                if vertical == .top { result.top = radius } else { result.bottom = radius }
            } else {
                if horizontal == .left { result.left = radius } else { result.right = radius }
            }
        }
        return result
    }
}

extension ViewportGeometry: RemoteCoordinateSpace {
    public var pointsPerRemotePixel: Double { scale }
}
