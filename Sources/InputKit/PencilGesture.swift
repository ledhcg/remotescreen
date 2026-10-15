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
