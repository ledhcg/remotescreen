#if os(macOS)
import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics
import Foundation
import LinkProtocol

/// Posts events with CoreGraphics at the HID event tap (`.cghidEventTap`), so they travel the same path as hardware events
/// and reach whichever window is topmost under the cursor. Needs the Accessibility / post-event permission.
///
/// Not exercised by `swift test` (it would move the real cursor). Behaviour on real apps is the subject of spike S9.
public struct CGEventPoster: EventPoster {
    /// Only used to create events, which is thread-safe.
    nonisolated(unsafe) private let source: CGEventSource?
    public let supportsGestures: Bool

    public init() {
        source = CGEventSource(stateID: .hidSystemState)
        supportsGestures = Self.probeGestureFields()
    }

    public var canPostEvents: Bool { CGPreflightPostEventAccess() }

    /// Asks the system to show its permission prompt for posting events. Returns the current state.
    @discardableResult
    public static func requestPostAccess() -> Bool { CGRequestPostEventAccess() }

    // MARK: Gesture fields (behavioural observations, not documented API)

    /// Undocumented event type and fields used for pinch/rotate. These numbers are what other event-synthesising tools
    /// were observed to use; they are *unverified here* and probed at runtime, and S9 decides go/no-go per macOS version:
    ///  - event type 29 carries a gesture; type 30 is the magnify type;
    ///  - field 110 is the gesture subtype (8 = magnify, 5 = rotate; 61 = smart-magnify);
    ///  - field 113 is the magnification delta, field 114 the rotation in degrees;
    ///  - field 132 is the gesture phase (1 began, 2 changed, 4 ended, 8 cancelled).
    enum GestureConstants {
        static let eventType: UInt32 = 29
        static let subtypeField: UInt32 = 110
        static let magnificationField: UInt32 = 113
        static let rotationField: UInt32 = 114
        static let phaseField: UInt32 = 132
        static let magnifySubtype: Int64 = 8
        static let rotateSubtype: Int64 = 5
        static let smartMagnifySubtype: Int64 = 61
    }

    /// The capability probe: an event of the gesture type can be created and a field written to it reads back.
    static func probeGestureFields() -> Bool {
        guard let type = CGEventType(rawValue: GestureConstants.eventType),
              let event = CGEvent(source: nil) else { return false }
        event.type = type
        guard let field = CGEventField(rawValue: GestureConstants.subtypeField) else { return false }
        event.setIntegerValueField(field, value: GestureConstants.magnifySubtype)
        return event.getIntegerValueField(field) == GestureConstants.magnifySubtype && event.type == type
    }

    // MARK: Posting

    public func post(_ event: SyntheticEvent) throws {
        guard canPostEvents else { throw EventPosterError.notPermitted }
        switch event {
        case .mouseMove(let point, let modifiers, let pen):
            try postMouse(.mouseMoved, button: .left, point: point, modifiers: modifiers, pen: pen, clickCount: nil)
        case .mouseDown(let button, let point, let count, let modifiers, let pen):
            try postMouse(Self.downType(button), button: button, point: point, modifiers: modifiers, pen: pen, clickCount: count)
        case .mouseUp(let button, let point, let count, let modifiers, let pen):
            try postMouse(Self.upType(button), button: button, point: point, modifiers: modifiers, pen: pen, clickCount: count)
        case .mouseDrag(let button, let point, let modifiers, let pen):
            try postMouse(Self.dragType(button), button: button, point: point, modifiers: modifiers, pen: pen, clickCount: nil)
        case .scroll(let point, let dx, let dy, let continuous, let phase, let momentum, let modifiers):
            try postScroll(at: point, dx: dx, dy: dy, continuous: continuous, phase: phase, momentum: momentum, modifiers: modifiers)
        case .key(let keycode, let down, let modifiers):
            guard let cg = CGEvent(keyboardEventSource: source, virtualKey: keycode, keyDown: down) else { throw EventPosterError.creationFailed }
            cg.flags = Self.flags(modifiers)
            cg.post(tap: .cghidEventTap)
        case .unicode(let text):
            try postUnicode(text)
        case .tabletProximity(let entering, let point):
            guard let cg = CGEvent(source: source) else { throw EventPosterError.creationFailed }
            cg.type = .tabletProximity
            cg.location = CGPoint(x: point.x, y: point.y)
            cg.setIntegerValueField(.tabletProximityEventEnterProximity, value: entering ? 1 : 0)
            cg.setIntegerValueField(.tabletProximityEventPointerType, value: 1) // pen
            cg.setIntegerValueField(.tabletProximityEventCapabilityMask, value: 0xFF)
            cg.post(tap: .cghidEventTap)
        case .gesture(let kind, let phase, let value, let point):
            try postGesture(kind: kind, phase: phase, value: value, at: point)
        }
    }

    private func postMouse(_ type: CGEventType, button: SyntheticButton, point: LinkPoint, modifiers: LinkModifiers,
                           pen: PenState?, clickCount: Int?) throws {
        guard let cg = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: CGPoint(x: point.x, y: point.y),
                               mouseButton: Self.cgButton(button)) else { throw EventPosterError.creationFailed }
        cg.flags = Self.flags(modifiers)
        if let clickCount { cg.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount)) }
        if button == .other { cg.setIntegerValueField(.mouseEventButtonNumber, value: 3) }
        if let pen {
            cg.setIntegerValueField(.mouseEventSubtype, value: 1) // tablet point
            cg.setDoubleValueField(.mouseEventPressure, value: Double(pen.pressure))
            cg.setDoubleValueField(.tabletEventPointPressure, value: Double(pen.pressure))
            cg.setDoubleValueField(.tabletEventTiltX, value: Double(pen.tiltX))
            cg.setDoubleValueField(.tabletEventTiltY, value: Double(pen.tiltY))
            cg.setDoubleValueField(.tabletEventRotation, value: Double(pen.rotation))
        }
        cg.post(tap: .cghidEventTap)
    }

    private func postScroll(at point: LinkPoint, dx: Double, dy: Double, continuous: Bool, phase: LinkScrollPhase,
                            momentum: LinkScrollPhase, modifiers: LinkModifiers) throws {
        let units: CGScrollEventUnit = continuous ? .pixel : .line
        guard let cg = CGEvent(scrollWheelEvent2Source: source, units: units, wheelCount: 2,
                               wheel1: Int32(clamping: Int(dy.rounded())), wheel2: Int32(clamping: Int(dx.rounded())), wheel3: 0)
        else { throw EventPosterError.creationFailed }
        cg.location = CGPoint(x: point.x, y: point.y)
        cg.flags = Self.flags(modifiers)
        if continuous {
            cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            cg.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: dy)
            cg.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: dx)
            cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: Self.scrollPhaseBits(phase))
            cg.setIntegerValueField(.scrollWheelEventMomentumPhase, value: Self.momentumPhaseValue(momentum))
        }
        cg.post(tap: .cghidEventTap)
    }

    private func postUnicode(_ text: String) throws {
        let units = Array(text.utf16)
        guard !units.isEmpty, units.count <= TextChunker.maxUTF16Units else { throw EventPosterError.creationFailed }
        for down in [true, false] {
            guard let cg = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) else { throw EventPosterError.creationFailed }
            cg.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
            cg.post(tap: .cghidEventTap)
        }
    }

    private func postGesture(kind: LinkGestureKind, phase: LinkGesturePhase, value: Double, at point: LinkPoint) throws {
        guard supportsGestures, let type = CGEventType(rawValue: GestureConstants.eventType),
              let subtypeField = CGEventField(rawValue: GestureConstants.subtypeField),
              let phaseField = CGEventField(rawValue: GestureConstants.phaseField),
              let valueField = CGEventField(rawValue: kind == .rotate ? GestureConstants.rotationField : GestureConstants.magnificationField),
              let cg = CGEvent(source: source) else { throw EventPosterError.creationFailed }
        cg.type = type
        cg.location = CGPoint(x: point.x, y: point.y)
        let subtype: Int64 = switch kind {
        case .magnify: GestureConstants.magnifySubtype
        case .rotate: GestureConstants.rotateSubtype
        case .smartMagnify: GestureConstants.smartMagnifySubtype
        case .swipe: GestureConstants.smartMagnifySubtype
        }
        cg.setIntegerValueField(subtypeField, value: subtype)
        cg.setIntegerValueField(phaseField, value: Self.gesturePhaseBits(phase))
        cg.setDoubleValueField(valueField, value: value)
        cg.post(tap: .cghidEventTap)
    }

    // MARK: Mapping

    static func cgButton(_ button: SyntheticButton) -> CGMouseButton {
        switch button {
        case .left: .left
        case .right: .right
        case .middle, .other: .center
        }
    }

    static func downType(_ button: SyntheticButton) -> CGEventType {
        switch button {
        case .left: .leftMouseDown
        case .right: .rightMouseDown
        case .middle, .other: .otherMouseDown
        }
    }

    static func upType(_ button: SyntheticButton) -> CGEventType {
        switch button {
        case .left: .leftMouseUp
        case .right: .rightMouseUp
        case .middle, .other: .otherMouseUp
        }
    }

    static func dragType(_ button: SyntheticButton) -> CGEventType {
        switch button {
        case .left: .leftMouseDragged
        case .right: .rightMouseDragged
        case .middle, .other: .otherMouseDragged
        }
    }

    static func flags(_ modifiers: LinkModifiers) -> CGEventFlags {
        var flags = CGEventFlags()
        if modifiers.contains(.shift) { flags.insert(.maskShift) }
        if modifiers.contains(.control) { flags.insert(.maskControl) }
        if modifiers.contains(.option) { flags.insert(.maskAlternate) }
        if modifiers.contains(.command) { flags.insert(.maskCommand) }
        if modifiers.contains(.capsLock) { flags.insert(.maskAlphaShift) }
        if modifiers.contains(.function) { flags.insert(.maskSecondaryFn) }
        return flags
    }

    /// `NSEventPhase`-style bits used by the scroll phase field.
    static func scrollPhaseBits(_ phase: LinkScrollPhase) -> Int64 {
        switch phase {
        case .none: 0
        case .began: 1
        case .changed: 4
        case .ended: 8
        case .cancelled: 16
        }
    }

    /// `CGMomentumScrollPhase`: 0 none, 1 begin, 2 continue, 3 end.
    static func momentumPhaseValue(_ phase: LinkScrollPhase) -> Int64 {
        switch phase {
        case .none: 0
        case .began: 1
        case .changed: 2
        case .ended, .cancelled: 3
        }
    }

    static func gesturePhaseBits(_ phase: LinkGesturePhase) -> Int64 {
        switch phase {
        case .began: 1
        case .changed: 2
        case .ended: 4
        case .cancelled: 8
        }
    }
}

/// `IsSecureEventInputEnabled()`: true while some process (a password field, a terminal's "Secure Keyboard Entry") has
/// secure input on, which makes synthetic key events unreliable or ignored.
public struct SystemSecureInputProbe: SecureInputProbe {
    public init() {}
    public func isSecureInputEnabled() -> Bool { IsSecureEventInputEnabled() }
}
#endif
