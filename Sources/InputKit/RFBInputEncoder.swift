import Foundation
import RFBKit

/// Turns protocol-neutral `InputIntent`s into RFB `ClientMessage`s for Apple Screen Sharing and other VNC servers.
///
/// Stateless: every intent carries what it needs. Rounding and clamping to the 16-bit RFB coordinates happen here, and
/// scroll lines become wheel button presses (buttons 4 to 7), exactly as the input pipeline always sent them.
public struct RFBInputEncoder: Sendable {
    // Wheel buttons in the RFB pointer mask.
    static let wheelUp: UInt8 = 1 << 3
    static let wheelDown: UInt8 = 1 << 4
    static let wheelLeft: UInt8 = 1 << 5
    static let wheelRight: UInt8 = 1 << 6

    public init() {}

    public func encode(_ intents: [InputIntent]) -> [ClientMessage] {
        intents.flatMap(encode)
    }

    public func encode(_ intent: InputIntent) -> [ClientMessage] {
        switch intent {
        case .pointer(let point, let buttons, _):
            // RFB carries modifiers as separate key events, so the `modifiers` hint is ignored.
            return [.pointerEvent(buttons: buttons.rawValue, x: Self.pixel(point.x), y: Self.pixel(point.y))]

        case .scroll(let point, let buttons, let dx, let dy, let phase, let momentum, let isContinuous):
            if isContinuous { return [Self.smoothScroll(at: point, dx: dx, dy: dy, phase: phase, momentum: momentum)] }
            return Self.wheelTicks(at: point, buttons: buttons, dx: dx, dy: dy)

        case .gesture(let kind, let point, let value, let phase):
            let x = Self.pixel(point.x), y = Self.pixel(point.y)
            let gesturePhase: AppleGesturePhase = switch phase {
            case .began: .began
            case .ended: .ended
            case .changed, .none: .changed
            }
            switch kind {
            case .magnify: return [.appleEvent(.magnify(value, phase: gesturePhase, x: x, y: y))]
            case .rotate: return [.appleEvent(.rotate(value, phase: gesturePhase, x: x, y: y))]
            case .smartZoom: return [] // no RFB message for it
            }

        case .key(let stroke):
            return [.keyEvent(isDown: stroke.isDown, keysym: stroke.keysym)]

        case .text(let text):
            return KeyboardState.typingKeysyms(text).flatMap { keysym in
                [.keyEvent(isDown: true, keysym: keysym), .keyEvent(isDown: false, keysym: keysym)]
            }

        case .tablet:
            return [] // RFB has no pressure or tilt
        }
    }

    // MARK: - Details

    /// Rounds to a whole pixel and clamps to the 16-bit range of the RFB pointer event. NaN becomes 0.
    static func pixel(_ value: Double) -> UInt16 {
        guard value.isFinite else { return value > 0 ? UInt16.max : 0 }
        return UInt16(min(max(value.rounded(), 0), Double(UInt16.max)))
    }

    private static func int32(_ value: Double) -> Int32 {
        guard value.isFinite else { return value > 0 ? Int32.max : (value < 0 ? Int32.min : 0) }
        return Int32(min(max(value.rounded(.towardZero), Double(Int32.min)), Double(Int32.max)))
    }

    /// Trackpad-style scrolling (Apple message 23, type 11).
    private static func smoothScroll(at point: RemotePoint, dx: Double, dy: Double, phase: InputPhase, momentum: InputPhase) -> ClientMessage {
        let scrollPhase: AppleScroll.Phase = switch phase {
        case .none: .none
        case .began: .began
        case .changed: .changed
        case .ended: .ended
        }
        let momentumPhase: AppleScroll.Momentum = switch momentum {
        case .none: .none
        case .began: .begin
        case .changed: .continue
        case .ended: .end
        }
        return .appleEvent(.scroll(AppleScroll(
            deltaX: int32(dx), deltaY: int32(dy), phase: scrollPhase, momentum: momentumPhase,
            x: pixel(point.x), y: pixel(point.y)
        )))
    }

    /// Wheel ticks: each is a press then a release of a wheel button, with the held mouse buttons kept. Vertical first, then horizontal.
    /// Positive `dy` moves content down, which is the wheel-up button; so the scrolled direction is the opposite of the delta's sign.
    private static func wheelTicks(at point: RemotePoint, buttons: PointerButtons, dx: Double, dy: Double) -> [ClientMessage] {
        let x = pixel(point.x), y = pixel(point.y)
        let held = buttons.rawValue
        func ticks(_ lines: Double, negative: UInt8, positive: UInt8) -> [ClientMessage] {
            let count = Int(min(max(lines.isFinite ? lines.rounded(.towardZero) : 0, -1e6), 1e6))
            guard count != 0 else { return [] }
            let button = count > 0 ? positive : negative
            return (0..<abs(count)).flatMap { _ in
                [ClientMessage.pointerEvent(buttons: held | button, x: x, y: y), .pointerEvent(buttons: held, x: x, y: y)]
            }
        }
        // dy > 0: content moves down = scroll up (wheel up button). dx > 0: content moves right = scroll left.
        return ticks(dy, negative: wheelDown, positive: wheelUp) + ticks(dx, negative: wheelRight, positive: wheelLeft)
    }
}
