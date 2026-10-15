import CoreGraphics
import Foundation
import InputKit
import LinkProtocol

/// What happens to pointer input around the window's edge. Decided per gesture: a gesture is the span from the first pressed
/// button to the release of the last one. Moves with no button held are hover.
///
/// | policy | starts outside window and surfaces | leaves the window while pressed |
/// |---|---|---|
/// | `captureAndClamp` (default) | dropped, hover included | stays captured; coordinates clamp to the window edge |
/// | `captureUnclamped` | dropped | stays captured; coordinates continue past the edge |
/// | `dropOutside` | dropped | a release is sent at the edge, the rest of the gesture is dropped |
/// | `clampAlways` | clamped to the edge and delivered | clamped to the edge |
///
/// Starting a gesture inside means inside the window or any transient surface (menus extend past the window).
public enum InputRoutingPolicy: Sendable, Equatable {
    case captureAndClamp
    case captureUnclamped
    case dropOutside
    case clampAlways
}

/// One pointer event after routing, in window coordinates.
public struct RoutedPointer: Sendable, Equatable {
    public var point: LinkPoint
    /// May differ from the input: `dropOutside` sends a release when the pointer leaves.
    public var buttons: PointerButtons
    /// True while this event belongs to a gesture that started inside.
    public var isCaptured: Bool
}

/// Applies an `InputRoutingPolicy` to a stream of pointer events. Feed it every pointer event of one scene in order.
public struct InputRouter: Sendable, Equatable {
    public var policy: InputRoutingPolicy
    private var captured = false
    /// `dropOutside`: the gesture was cut off and is ignored until all buttons are up.
    private var suppressed = false

    public init(policy: InputRoutingPolicy = .captureAndClamp) { self.policy = policy }

    public var isCapturing: Bool { captured }

    /// Forgets the current gesture, for example when the touch was cancelled. The caller is responsible for sending a release.
    public mutating func cancel() { captured = false; suppressed = false }

    /// Routes one event. `nil` means drop it.
    public mutating func route(viewPoint: CGPoint, buttons: PointerButtons, in space: WindowCoordinateSpace) -> RoutedPointer? {
        guard space.isValid, viewPoint.x.isFinite, viewPoint.y.isFinite else { return nil }
        let raw = space.windowPoint(forView: viewPoint)
        let inside = space.contains(windowPoint: raw)
        defer {
            if buttons.isEmpty { captured = false; suppressed = false }
        }

        if suppressed { return nil }

        if captured {
            switch policy {
            case .captureAndClamp, .clampAlways:
                return routed(space.clamped(windowPoint: raw), buttons)
            case .captureUnclamped:
                return routed(Self.bounded(raw), buttons)
            case .dropOutside:
                if inside { return routed(raw, buttons) }
                captured = false
                suppressed = !buttons.isEmpty
                return RoutedPointer(point: Self.link(space.clamped(windowPoint: raw)), buttons: [], isCaptured: true)
            }
        }

        if policy == .clampAlways {
            captured = !buttons.isEmpty
            return routed(space.clamped(windowPoint: raw), buttons)
        }
        guard inside else {
            // A press that starts outside belongs to someone else; the rest of that gesture is ignored too.
            suppressed = !buttons.isEmpty
            return nil
        }
        captured = !buttons.isEmpty
        return routed(raw, buttons)
    }

    private func routed(_ point: CGPoint, _ buttons: PointerButtons) -> RoutedPointer {
        RoutedPointer(point: Self.link(point), buttons: buttons, isCaptured: captured)
    }

    private static func link(_ point: CGPoint) -> LinkPoint { LinkPoint(x: point.x, y: point.y) }

    private static func bounded(_ point: CGPoint) -> CGPoint {
        let limit = LinkLimits.maxCoordinate
        return CGPoint(x: min(max(point.x, -limit), limit), y: min(max(point.y, -limit), limit))
    }
}
