import CoreGraphics
import Foundation

/// What an Apple Pencil stroke does on the Mac. Coordinates are view coordinates (points); `TouchMapper` converts them to Mac pixels.
public enum PencilAction: Sendable, Equatable {
    /// Press the left button at the stroke's start point (starts drag and drop, or text selection).
    case press(CGPoint)
    /// Continue dragging with the left button still down.
    case move(CGPoint)
    /// Release the left button (end of drag).
    case release(CGPoint)
    /// Left click (pencil tap).
    case click(CGPoint)
    /// Right click (pencil held still for a long time).
    case rightClick(CGPoint)
}

/// What the Apple Pencil reports at one moment, for targets that draw (App Mode's tablet events). Screen Sharing (RFB) has no use for it:
/// `RFBInputEncoder` ignores the `tablet` intents it produces, and a mapper that is never given a sample behaves exactly as before.
public struct PencilSample: Sendable, Equatable {
    /// 0...1.
    public var pressure: Double
    /// Tilt away from vertical along each screen axis, in radians (-pi/2...pi/2). 0 is upright.
    public var tiltX: Double
    public var tiltY: Double
    /// Direction the pencil leans towards, in radians in the view's coordinates.
    public var azimuth: Double

    public init(pressure: Double, tiltX: Double, tiltY: Double, azimuth: Double = 0) {
        self.pressure = Self.finite(pressure, in: 0...1)
        self.tiltX = Self.finite(tiltX, in: (-Double.pi / 2)...(Double.pi / 2))
        self.tiltY = Self.finite(tiltY, in: (-Double.pi / 2)...(Double.pi / 2))
        self.azimuth = azimuth.isFinite ? azimuth : 0
    }

    /// From `UITouch`: `force` and `maximumPossibleForce`, `altitudeAngle` (0 flat on the screen, pi/2 upright) and `azimuthAngle`.
    public init(force: Double, maximumForce: Double, altitude: Double, azimuth: Double) {
        let pressure = maximumForce > 0 && force.isFinite && maximumForce.isFinite ? force / maximumForce : 0
        let alt = Self.finite(altitude, in: 0...(Double.pi / 2))
        let az = azimuth.isFinite ? azimuth : 0
        // The pencil's direction from the tip is (cos(alt) cos(az), cos(alt) sin(az), sin(alt)); tilt along an axis is its angle from upright
        // in that axis's plane.
        self.init(
            pressure: pressure, tiltX: Self.tilt(cos(alt) * cos(az), sin(alt)), tiltY: Self.tilt(cos(alt) * sin(az), sin(alt)), azimuth: az
        )
    }

    /// Angle from upright of a pencil whose direction has components `lean` (along the axis) and `up` (away from the screen). A pencil
    /// lying flat and square to the axis has no defined tilt along it: 0.
    private static func tilt(_ lean: Double, _ up: Double) -> Double {
        hypot(lean, up) < 1e-9 ? 0 : atan2(lean, up)
    }

    private static func finite(_ value: Double, in range: ClosedRange<Double>) -> Double {
        value.isFinite ? min(max(value, range.lowerBound), range.upperBound) : 0
    }
}

/// Classifies a pencil stroke: tap, drag or hold still. Pure (time is passed in), so it can be tested without UI.
///
/// The pencil is an **absolute, precise** pointer regardless of direct-touch or trackpad mode: wherever the tip is, the Mac pointer is there.
/// - Touch then lift (shorter than `rightClickDuration`, not moving past `slop`): left click.
/// - Moving past `slop`: drag and drop immediately, with no need to hold first like a finger (the pencil does not need to be told apart from scrolling).
/// - Held still for `rightClickDuration` or longer, then lifted: right click.
public struct PencilGesture: Sendable, Equatable {
    /// Distance the pencil tip may drift and still count as a tap, in points. Much smaller than for a finger because the tip is precise.
    public static let slop: CGFloat = 4
    public static let rightClickDuration = 0.6

    private var start: CGPoint?
    private var startTime = 0.0
    private var last = CGPoint.zero
    private var isDragging = false

    public init() {}

    public mutating func began(at point: CGPoint, time: Double) -> [PencilAction] {
        start = point
        startTime = time
        last = point
        isDragging = false
        return []
    }

    public mutating func moved(to point: CGPoint, time: Double) -> [PencilAction] {
        guard let start else { return [] }
        last = point
        if isDragging { return [.move(point)] }
        guard hypot(point.x - start.x, point.y - start.y) > Self.slop else { return [] }
        isDragging = true
        return [.press(start), .move(point)]
    }

    public mutating func ended(at point: CGPoint, time: Double) -> [PencilAction] {
        guard let start else { return [] }
        defer { reset() }
        if isDragging { return [.move(point), .release(point)] }
        return time - startTime >= Self.rightClickDuration ? [.rightClick(start)] : [.click(start)]
    }

    /// Stroke cancelled (the system took the touch): release if dragging, otherwise ignore (no accidental click).
    public mutating func cancelled() -> [PencilAction] {
        defer { reset() }
        return isDragging ? [.release(last)] : []
    }

    private mutating func reset() {
        start = nil
        isDragging = false
    }
}
