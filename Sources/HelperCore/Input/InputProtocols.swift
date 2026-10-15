#if os(macOS)
import Foundation
import LinkProtocol

/// A mouse button as the Mac numbers them (`CGMouseButton`: left 0, right 1, centre 2, others 3...).
public enum SyntheticButton: UInt8, Sendable, Hashable, CaseIterable {
    case left = 0, right, middle, other
}

/// Pen state attached to a mouse event so that drawing apps see a tablet stylus.
public struct PenState: Sendable, Equatable {
    /// 0...1.
    public var pressure: Float
    /// -1...1 on each axis.
    public var tiltX: Float
    public var tiltY: Float
    public var rotation: Float
    public init(pressure: Float, tiltX: Float = 0, tiltY: Float = 0, rotation: Float = 0) {
        self.pressure = pressure; self.tiltX = tiltX; self.tiltY = tiltY; self.rotation = rotation
    }
}

/// One event the helper wants the system to see. Coordinates are **global Mac points** (already resolved by the injector).
public enum SyntheticEvent: Sendable, Equatable {
    case mouseMove(at: LinkPoint, modifiers: LinkModifiers, pen: PenState?)
    case mouseDown(button: SyntheticButton, at: LinkPoint, clickCount: Int, modifiers: LinkModifiers, pen: PenState?)
    case mouseUp(button: SyntheticButton, at: LinkPoint, clickCount: Int, modifiers: LinkModifiers, pen: PenState?)
    case mouseDrag(button: SyntheticButton, at: LinkPoint, modifiers: LinkModifiers, pen: PenState?)
    /// `dx`/`dy` are pixels when `continuous`, lines otherwise.
    case scroll(at: LinkPoint, dx: Double, dy: Double, continuous: Bool, phase: LinkScrollPhase,
                momentumPhase: LinkScrollPhase, modifiers: LinkModifiers)
    case key(keycode: UInt16, down: Bool, modifiers: LinkModifiers)
    /// A key down + key up pair carrying this text as its Unicode string. Never more than `TextChunker.maxUTF16Units` units.
    case unicode(String)
    case tabletProximity(entering: Bool, at: LinkPoint)
    case gesture(kind: LinkGestureKind, phase: LinkGesturePhase, value: Double, at: LinkPoint)
}

/// Posts events to the system. The real implementation is `CGEventPoster`; tests use a recording fake.
public protocol EventPoster: Sendable {
    /// Whether the process may post events (`CGPreflightPostEventAccess`). When false, `post` would be silently ignored.
    var canPostEvents: Bool { get }
    /// Capability probe for the undocumented gesture fields (`GestureInjection`).
    var supportsGestures: Bool { get }
    func post(_ event: SyntheticEvent) throws
}

/// The current frame of a window on the Mac, in global points (top-left origin, as `CGWindowList`/AX report it).
/// Implemented by the window tracker. `nil` means unknown or destroyed.
public protocol WindowGeometryProvider: Sendable {
    func contentFrame(of window: WindowID) async -> LinkRect?
}

/// Brings a window to the front. Used before a pointer press ("focus follows interaction").
public protocol WindowFocuser: Sendable {
    /// Whether `window` is the topmost window at the global point `point`.
    func isFrontmost(_ window: WindowID, at point: LinkPoint) async -> Bool
    /// The topmost window that has keyboard focus, or nil when it is not a window the helper tracks (or is unknown).
    func frontmostWindow() async -> WindowID?
    /// Raise the window and activate its application.
    func raiseAndActivate(_ window: WindowID) async
}

/// `IsSecureEventInputEnabled()` behind a protocol.
public protocol SecureInputProbe: Sendable {
    func isSecureInputEnabled() -> Bool
}

/// What the injector tells the session layer, which turns it into `status` messages.
public enum InputInjectorEvent: Sendable, Equatable {
    case secureInputChanged(Bool)
    /// Posting is not allowed (Accessibility / post-event access missing).
    case postingNotPermitted
}

public enum EventPosterError: Error, Equatable {
    case creationFailed
    case notPermitted
}
#endif
