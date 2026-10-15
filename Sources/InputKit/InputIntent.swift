import Foundation

/// A position on the remote surface, in the coordinate space's own unit (Mac pixels for a full-screen RFB session, Mac points for
/// a window-relative space). Kept as `Double` so a protocol encoder decides how to round it; the RFB encoder rounds to whole pixels.
public struct RemotePoint: Sendable, Equatable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// Mouse buttons held down. The bit values match the low bits of the RFB pointer button mask. Scroll wheels are not buttons here:
/// they are `InputIntent.scroll`.
public struct PointerButtons: OptionSet, Sendable, Hashable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let left = PointerButtons(rawValue: 1 << 0)
    public static let middle = PointerButtons(rawValue: 1 << 1)
    public static let right = PointerButtons(rawValue: 1 << 2)
}

/// Phase of a continuous input (scroll, momentum, gesture). `none` means the source does not report a phase for this step.
public enum InputPhase: Sendable, Equatable {
    case none, began, changed, ended
}

public enum GestureKind: Sendable, Equatable {
    /// Pinch: `value` is the relative scale change since the previous step (0.05 zooms in another 5%).
    case magnify
    /// Rotation: `value` is in degrees, positive is counterclockwise.
    case rotate
    /// Two-finger double tap (smart zoom). `value` is unused.
    case smartZoom
}

/// One key press or release. `keysym` is the X11 keysym (what RFB sends). `macKeyCode` is the Mac virtual key code (`kVK_*`) when the
/// source knows it, for encoders that inject keys by code instead of by keysym.
public struct KeyStroke: Sendable, Equatable {
    public var keysym: UInt32
    public var macKeyCode: UInt16?
    public var isDown: Bool

    public init(keysym: UInt32, macKeyCode: UInt16? = nil, isDown: Bool) {
        self.keysym = keysym
        self.macKeyCode = macKeyCode
        self.isDown = isDown
    }
}

/// What the user did, independent of the wire protocol. `TouchMapper`, the keyboard and the modifier keys produce intents;
/// an encoder (`RFBInputEncoder` for Screen Sharing, a link encoder for App Mode) turns them into protocol messages.
public enum InputIntent: Sendable, Equatable {
    /// The pointer is at `at` with `buttons` held. `modifiers` is the keyboard state the source wants applied to this event, or `nil` when
    /// modifiers travel as separate key events (RFB).
    case pointer(at: RemotePoint, buttons: PointerButtons, modifiers: KeyModifiers?)

    /// Scroll at `at`. `dx` and `dy` use the `NSEvent.scrollingDelta` convention: positive `dy` moves the content down, positive `dx` moves it
    /// right. Units are points when `isContinuous` (trackpad-style, with phases) and wheel lines otherwise (phases are `none`).
    /// `buttons` is the mouse state at the time, because RFB wheel ticks are button events.
    case scroll(
        at: RemotePoint, buttons: PointerButtons, dx: Double, dy: Double,
        phase: InputPhase, momentumPhase: InputPhase, isContinuous: Bool
    )

    /// Pinch, rotation or smart zoom at `at`. A gesture starts with `began` (value 0), continues with `changed`, and ends with `ended` (value 0).
    case gesture(kind: GestureKind, at: RemotePoint, value: Double, phase: InputPhase)

    case key(KeyStroke)

    /// Text to insert as typed (final characters, already composed by the iPad's input method).
    case text(String)

    /// Apple Pencil state for tablet-capable targets. Pressure is 0...1, tilt in radians.
    case tablet(at: RemotePoint, pressure: Double, tiltX: Double, tiltY: Double)
}

extension InputIntent {
    /// Convenience for a key press or release without a Mac key code.
    public static func key(_ keysym: UInt32, macKeyCode: UInt16? = nil, isDown: Bool) -> InputIntent {
        .key(KeyStroke(keysym: keysym, macKeyCode: macKeyCode, isDown: isDown))
    }

    /// Press and release of one key.
    public static func tap(_ keysym: UInt32, macKeyCode: UInt16? = nil) -> [InputIntent] {
        [.key(keysym, macKeyCode: macKeyCode, isDown: true), .key(keysym, macKeyCode: macKeyCode, isDown: false)]
    }
}
