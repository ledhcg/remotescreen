import CoreGraphics
import Foundation
import RFBKit

/// How to convert coordinates between the viewport and the remote screen. `ViewportGeometry` (in RemoteDisplay) conforms to this protocol,
/// so `InputKit` does not need to know anything about Metal or UIKit.
public protocol RemoteCoordinateSpace {
    var remoteSize: CGSize { get }
    /// Points per Mac pixel at the current zoom level.
    var pointsPerRemotePixel: Double { get }
    /// With `clamped == false`, returns `nil` when the point falls outside the screen (a touch on the black border).
    func remotePixel(forView point: CGPoint, clamped: Bool) -> (x: Int, y: Int)?
}

public enum TouchMode: Sendable, Equatable {
    /// Wherever you touch, the action happens right there on the Mac screen (like a touchscreen).
    case directTouch
    /// The finger moves the pointer relatively, like a trackpad: drag to move, tap to click at the pointer.
    case trackpad
}

public enum DragBehavior: Sendable, Equatable {
    /// Only moves the pointer (hover, no press).
    case moveCursor
    /// Holds the left button down and drags (text selection, drag and drop).
    case dragWithLeftButton
    /// Pans the viewport and sends nothing to the Mac. Useful when zoomed in.
    case panViewport
}

public enum TwoFingerBehavior: Sendable, Equatable {
    /// Scrolls with the mouse wheel.
    case scroll
    case panViewport
}

/// Choices about how gestures are interpreted. Gathered in one place so they are easy to tune to habit.
public struct TouchPolicy: Sendable, Equatable {
    public var mode: TouchMode = .directTouch
    /// iOS-style scrolling: dragging the finger up moves content up (that is, scrolls down).
    public var naturalScrolling = true
    /// Points the finger must travel to produce one scroll tick.
    public var scrollTickDistance = 24.0
    /// Multiplier for movement speed in trackpad mode.
    public var trackpadSensitivity = 1.6
    /// Apple server with the user having enabled "smooth scrolling": scroll with `kCGEventScrollWheel` carrying phases and momentum (message 23) instead of
    /// wheel ticks. Other servers do not understand this message, so it is off by default.
    public var appleSmoothScroll = false
    /// Framebuffer pixels per Mac point, so content on the Mac moves exactly as far as the finger. 1 was checked on a real Mac
    /// (2560x1440 at 1x: `NSEvent.scrollingDeltaY` equals the distance sent). A Retina Mac may need 2 if the framebuffer is measured in
    /// real pixels; no Retina machine was available to measure, and RFB does not report this ratio.
    public var remotePixelsPerMacPoint = 1.0

    public init(mode: TouchMode = .directTouch) {
        self.mode = mode
    }

    /// **What does a one-finger drag do?** This is the app's most important UX decision.
    ///
    /// Default: trackpad mode always moves the pointer; direct-touch mode pans the viewport while zoomed in
    /// (to see the off-screen part) and moves the pointer when not zoomed. A real drag and drop uses press-and-hold, then drag.
    public func oneFingerDrag(isZoomed: Bool) -> DragBehavior {
        switch mode {
        case .trackpad: .moveCursor
        case .directTouch: isZoomed ? .panViewport : .moveCursor
        }
    }

    /// **What does a two-finger drag do?** Default is scrolling, except when zoomed in, where it pans the viewport.
    public func twoFingerPan(isZoomed: Bool) -> TwoFingerBehavior {
        isZoomed ? .panViewport : .scroll
    }
}

public enum GesturePhase: Sendable, Equatable {
    case began, changed, ended
}

/// A recognized gesture, decoupled from UIKit.
public enum TouchEvent: Sendable, Equatable {
    case tap(CGPoint, count: Int)
    case twoFingerTap(CGPoint)
    case longPress(CGPoint, GesturePhase)
    /// A one-finger drag. `location` is the current position, `translation` is the distance moved since the previous event.
    case pan(location: CGPoint, translation: CGPoint, GesturePhase)
    case twoFingerPan(location: CGPoint, translation: CGPoint, GesturePhase)
    /// A classified Apple Pencil stroke (`PencilGesture`). Always absolute, regardless of touch mode.
    case pencil(PencilAction)
    /// Pointer movement without a button press: iPad mouse or trackpad, hovering pencil. Always absolute.
    case hover(CGPoint)
    /// iPad mouse button (or trackpad click): press (`began`), drag (`changed`), release (`ended`) at an absolute position.
    case mouseButton(CGPoint, MouseButton, GesturePhase)
    /// Scrolling with a mouse wheel or two fingers on the iPad trackpad: always scrolls the Mac (even while zoomed), at the pointer position.
    case scroll(location: CGPoint, translation: CGPoint, GesturePhase)
    /// Right click at the current pointer position (double tap on Apple Pencil).
    case secondaryClickAtPointer
    /// Pinch sent to the Mac (message 23 type 3): `scaleDelta` is the scale change since the last step (0.05 = zoom in another 5%).
    case magnify(location: CGPoint, scaleDelta: Double, GesturePhase)
    /// Rotation sent to the Mac (message 23 type 5): degrees, positive is counterclockwise.
    case rotate(location: CGPoint, degrees: Double, GesturePhase)
}

/// A button of a mouse or trackpad attached to the iPad.
public enum MouseButton: Sendable, Equatable {
    case primary, secondary
}

/// What to do after a gesture.
public struct TouchOutput: Equatable, Sendable {
    /// What to do on the Mac, in order, independent of the wire protocol (`RFBInputEncoder` turns it into RFB messages).
    public var intents: [InputIntent] = []
    /// If present, the viewport must pan by this many points.
    public var viewportPan: CGPoint?
}

/// Turns touch gestures into protocol-neutral pointer, scroll and gesture intents.
public struct TouchMapper: Sendable {
    public var policy: TouchPolicy

    /// Pointer position on the Mac screen, in Mac pixels.
    public private(set) var pointer: (x: Int, y: Int) {
        didSet { hasPointer = true }
    }
    /// `true` once the app has placed the pointer for the first time. Before that we do not know where the Mac's real pointer is
    /// (RFB does not report the position), so we should not draw a fake pointer at (0, 0).
    public private(set) var hasPointer = false
    private var buttons: PointerButtons = []
    private var lastLocation: CGPoint?
    private var scrollAccumulator = CGPoint.zero
    private var isDragging = false
    private enum AppleScrollState { case idle, scrolling, momentum }
    private var appleScrollState = AppleScrollState.idle
    private var appleScrollRemainder = CGPoint.zero

    static let leftButton = PointerButtons.left
    static let rightButton = PointerButtons.right

    /// - Parameter initialPointer: pointer position if known. Omitting it means unknown (`hasPointer == false`).
    public init(policy: TouchPolicy = TouchPolicy(), initialPointer: (x: Int, y: Int)? = nil) {
        self.policy = policy
        pointer = initialPointer ?? (0, 0)
        hasPointer = initialPointer != nil
    }

    public mutating func handle(_ event: TouchEvent, in space: some RemoteCoordinateSpace, isZoomed: Bool) -> TouchOutput {
        var output = TouchOutput()
        switch event {
        case .tap(let point, let count):
            guard let target = target(at: point, in: space) else { return output }
            for _ in 0..<max(1, count) { output.intents += click(Self.leftButton, at: target) }

        case .twoFingerTap(let point):
            guard let target = target(at: point, in: space) else { return output }
            output.intents += click(Self.rightButton, at: target)

        case .longPress(let point, let phase):
            output.intents += dragStep(to: point, phase: phase, in: space)

        case .pan(let location, let translation, let phase):
            switch policy.oneFingerDrag(isZoomed: isZoomed) {
            case .moveCursor:
                if let target = movedTarget(location: location, translation: translation, phase: phase, in: space) {
                    output.intents.append(pointerIntent(target))
                }
            case .dragWithLeftButton:
                output.intents += dragStep(to: location, phase: phase, in: space)
            case .panViewport:
                if phase == .changed { output.viewportPan = translation }
            }

        case .twoFingerPan(let location, let translation, let phase):
            switch policy.twoFingerPan(isZoomed: isZoomed) {
            case .scroll:
                output.intents += scroll(location: location, translation: translation, phase: phase, in: space)
            case .panViewport:
                if phase == .changed { output.viewportPan = translation }
            }

        case .pencil(let action):
            output.intents += pencil(action, in: space)

        case .hover(let location):
            if let target = absoluteTarget(location, in: space) { output.intents.append(pointerIntent(target)) }

        case .mouseButton(let location, let button, let phase):
            let bit = button == .primary ? Self.leftButton : Self.rightButton
            guard let target = absoluteTarget(location, in: space) else { return output }
            switch phase {
            case .began:
                output.intents.append(pointerIntent(target))
                buttons.insert(bit)
            case .changed:
                break
            case .ended:
                buttons.remove(bit)
            }
            output.intents.append(pointerIntent(target))

        case .scroll(let location, let translation, let phase):
            output.intents += scroll(location: location, translation: translation, phase: phase, in: space, atLocation: true)

        case .secondaryClickAtPointer:
            guard hasPointer else { return output }
            output.intents += click(Self.rightButton, at: pointer)

        case .magnify(let location, let delta, let phase):
            output.intents += gesture(.magnify, at: location, value: delta, phase: phase, in: space)

        case .rotate(let location, let degrees, let phase):
            output.intents += gesture(.rotate, at: location, value: degrees, phase: phase, in: space)
        }
        return output
    }

    /// Releases every held button (when a gesture is cancelled, on backgrounding, on disconnect) so the Mac is not left with a stuck mouse button.
    public mutating func releaseAll() -> [InputIntent] {
        defer { buttons = []; isDragging = false; lastLocation = nil; scrollAccumulator = .zero }
        guard !buttons.isEmpty else { return [] }
        return [.pointer(at: RemotePoint(x: Double(pointer.x), y: Double(pointer.y)), buttons: [], modifiers: nil)]
    }

    // MARK: - Choosing a position

    /// Direct touch: the touch point. Trackpad: the current pointer position. `nil` for a touch on the black border in direct mode.
    private mutating func target(at point: CGPoint, in space: some RemoteCoordinateSpace) -> (x: Int, y: Int)? {
        switch policy.mode {
        case .directTouch:
            guard let pixel = space.remotePixel(forView: point, clamped: false) else { return nil }
            pointer = pixel
            return pixel
        case .trackpad:
            return pointer
        }
    }

    /// New position when one finger drags in "move pointer" mode.
    private mutating func movedTarget(
        location: CGPoint, translation: CGPoint, phase: GesturePhase, in space: some RemoteCoordinateSpace
    ) -> (x: Int, y: Int)? {
        switch policy.mode {
        case .directTouch:
            guard let pixel = space.remotePixel(forView: location, clamped: true) else { return nil }
            pointer = pixel
            return pixel
        case .trackpad:
            guard phase == .changed else { return nil }
            // If the real pointer position is unknown, start from the screen center, not from the (0, 0) corner.
            if !hasPointer {
                pointer = (Int(space.remoteSize.width) / 2, Int(space.remoteSize.height) / 2)
            }
            let scale = max(space.pointsPerRemotePixel, 0.0001)
            let dx = Double(translation.x) / scale * policy.trackpadSensitivity
            let dy = Double(translation.y) / scale * policy.trackpadSensitivity
            pointer = (
                min(max(pointer.x + Int(dx.rounded()), 0), Int(space.remoteSize.width) - 1),
                min(max(pointer.y + Int(dy.rounded()), 0), Int(space.remoteSize.height) - 1)
            )
            return pointer
        }
    }

    /// Absolute position (pencil, mouse): the point under the pencil tip or pointer, clamped to the Mac screen.
    private mutating func absoluteTarget(_ location: CGPoint, in space: some RemoteCoordinateSpace) -> (x: Int, y: Int)? {
        guard let pixel = space.remotePixel(forView: location, clamped: true) else { return nil }
        pointer = pixel
        return pixel
    }

    /// Pinch/rotate on the Mac: first move the pointer to the midpoint between the two fingers (Mac apps zoom around the pointer), then send each step.
    private mutating func gesture(
        _ kind: GestureKind, at location: CGPoint, value: Double, phase: GesturePhase, in space: some RemoteCoordinateSpace
    ) -> [InputIntent] {
        guard let target = space.remotePixel(forView: location, clamped: true) else { return [] }
        var messages: [InputIntent] = []
        if phase == .began, buttons.isEmpty {
            pointer = target
            messages.append(pointerIntent(target))
        }
        let at = RemotePoint(x: Double(pointer.x), y: Double(pointer.y))
        func step(_ value: Double, _ phase: InputPhase) -> InputIntent { .gesture(kind: kind, at: at, value: value, phase: phase) }
        // The Mac receives began and ended carrying no value (the form verified on a real machine); the change UIKit reports along with began/ended (fingers have
        // already pinched a little before the recognizer starts) is sent separately as a changed step so it is not lost.
        if phase == .began { messages.append(step(0, .began)) }
        if phase == .changed || value != 0 { messages.append(step(value, .changed)) }
        if phase == .ended { messages.append(step(0, .ended)) }
        return messages
    }

    private mutating func pencil(_ action: PencilAction, in space: some RemoteCoordinateSpace) -> [InputIntent] {
        switch action {
        case .press(let point):
            guard let target = absoluteTarget(point, in: space) else { return [] }
            let move = pointerIntent(target)
            buttons.insert(Self.leftButton)
            return [move, pointerIntent(target)]
        case .move(let point):
            guard let target = absoluteTarget(point, in: space) else { return [] }
            return [pointerIntent(target)]
        case .release(let point):
            buttons.remove(Self.leftButton)
            let target = absoluteTarget(point, in: space) ?? pointer
            return [pointerIntent(target)]
        case .click(let point), .rightClick(let point):
            // Pencil touching the black border outside the Mac screen: no click (like a finger).
            guard let pixel = space.remotePixel(forView: point, clamped: false) else { return [] }
            pointer = pixel
            if case .rightClick = action { return click(Self.rightButton, at: pixel) }
            return click(Self.leftButton, at: pixel)
        }
    }

    // MARK: - Click, drag, scroll

    private func pointerIntent(_ target: (x: Int, y: Int)) -> InputIntent {
        .pointer(at: RemotePoint(x: Double(target.x), y: Double(target.y)), buttons: buttons, modifiers: nil)
    }

    /// One click: move to the position, press, release.
    private mutating func click(_ button: PointerButtons, at target: (x: Int, y: Int)) -> [InputIntent] {
        let point = RemotePoint(x: Double(target.x), y: Double(target.y))
        return [
            .pointer(at: point, buttons: buttons, modifiers: nil),
            .pointer(at: point, buttons: buttons.union(button), modifiers: nil),
            .pointer(at: point, buttons: buttons, modifiers: nil),
        ]
    }

    /// Hold the left button and drag (used for press-and-hold-then-drag and for "one-finger drag = drag and drop").
    private mutating func dragStep(to location: CGPoint, phase: GesturePhase, in space: some RemoteCoordinateSpace) -> [InputIntent] {
        switch phase {
        case .began:
            guard let target = target(at: location, in: space) else { return [] }
            lastLocation = location
            isDragging = true
            let move = pointerIntent(target)
            buttons.insert(Self.leftButton)
            return [move, pointerIntent(target)]

        case .changed:
            guard isDragging else { return [] }
            let target: (x: Int, y: Int)?
            switch policy.mode {
            case .directTouch:
                target = space.remotePixel(forView: location, clamped: true)
            case .trackpad:
                let previous = lastLocation ?? location
                target = movedTarget(
                    location: location, translation: CGPoint(x: location.x - previous.x, y: location.y - previous.y),
                    phase: .changed, in: space
                )
            }
            lastLocation = location
            guard let target else { return [] }
            pointer = target
            return [pointerIntent(target)]

        case .ended:
            guard isDragging else { return [] }
            isDragging = false
            lastLocation = nil
            buttons.remove(Self.leftButton)
            return [pointerIntent(pointer)]
        }
    }

    /// Scrolling: accumulate drag distance, and every `scrollTickDistance` points produces one line of scroll (the RFB encoder sends it as a wheel button tick).
    /// - Parameter atLocation: scroll at `location` regardless of mode (mouse, iPad trackpad: there it is the pointer).
    private mutating func scroll(
        location: CGPoint, translation: CGPoint, phase: GesturePhase, in space: some RemoteCoordinateSpace,
        atLocation: Bool = false
    ) -> [InputIntent] {
        if policy.appleSmoothScroll {
            return appleScroll(location: location, translation: translation, phase: phase, in: space, atLocation: atLocation)
        }
        switch phase {
        case .began:
            scrollAccumulator = .zero
            return []
        case .ended:
            scrollAccumulator = .zero
            return []
        case .changed:
            scrollAccumulator.x += translation.x
            scrollAccumulator.y += translation.y
        }

        // Direct touch: scroll where the two fingers rest. Trackpad: at the pointer.
        let anchor = (policy.mode == .directTouch || atLocation ? space.remotePixel(forView: location, clamped: true) : nil) ?? pointer
        let tick = policy.scrollTickDistance

        func ticks(_ value: inout Double) -> Int {
            let whole = Int((value / tick).rounded(.towardZero))
            value -= Double(whole) * tick
            return whole
        }
        var vertical = Double(scrollAccumulator.y)
        var horizontal = Double(scrollAccumulator.x)
        let verticalTicks = ticks(&vertical)
        let horizontalTicks = ticks(&horizontal)
        scrollAccumulator = CGPoint(x: horizontal, y: vertical)

        // Finger moving up (negative translation.y) with natural scrolling means content moves up, which is scroll down. Intents use the
        // NSEvent convention (positive: content moves down / right), so natural scrolling passes the finger direction through.
        let lineY = policy.naturalScrolling ? verticalTicks : -verticalTicks
        let lineX = policy.naturalScrolling ? horizontalTicks : -horizontalTicks
        guard lineY != 0 || lineX != 0 else { return [] }
        pointer = anchor
        return [.scroll(
            at: RemotePoint(x: Double(anchor.x), y: Double(anchor.y)), buttons: buttons, dx: Double(lineX), dy: Double(lineY),
            phase: .none, momentumPhase: .none, isContinuous: false
        )]
    }

    /// Mac trackpad-style scrolling: began, changed..., ended; if steps remain after ended (the app's momentum) they become a momentum phase
    /// begin, continue..., end, so the Mac handles it like a real trackpad swipe (bounce at the edge, continued scrolling inside the app).
    private mutating func appleScroll(
        location: CGPoint, translation: CGPoint, phase: GesturePhase, in space: some RemoteCoordinateSpace, atLocation: Bool
    ) -> [InputIntent] {
        let anchor = (policy.mode == .directTouch || atLocation ? space.remotePixel(forView: location, clamped: true) : nil) ?? pointer
        let at = RemotePoint(x: Double(anchor.x), y: Double(anchor.y))
        func event(_ dx: Int32, _ dy: Int32, _ phase: InputPhase, _ momentum: InputPhase) -> InputIntent {
            .scroll(at: at, buttons: buttons, dx: Double(dx), dy: Double(dy), phase: phase, momentumPhase: momentum, isContinuous: true)
        }
        switch phase {
        case .began:
            appleScrollState = .scrolling
            appleScrollRemainder = .zero
            return [event(0, 0, .began, .none)]
        case .ended:
            defer { appleScrollState = .idle }
            switch appleScrollState {
            case .scrolling: return [event(0, 0, .ended, .none)]
            case .momentum: return [event(0, 0, .none, .ended)]
            case .idle: return []
            }
        case .changed:
            break
        }
        // Distance in Mac points, keeping the fractional part for the next call so slow scrolling is not lost.
        let scale = max(space.pointsPerRemotePixel, 0.0001) * policy.remotePixelsPerMacPoint
        let sign: CGFloat = policy.naturalScrolling ? 1 : -1
        appleScrollRemainder.x += sign * translation.x / scale
        appleScrollRemainder.y += sign * translation.y / scale
        let dx = Int32(clamping: Int(appleScrollRemainder.x.rounded(.towardZero)))
        let dy = Int32(clamping: Int(appleScrollRemainder.y.rounded(.towardZero)))
        appleScrollRemainder.x -= CGFloat(dx)
        appleScrollRemainder.y -= CGFloat(dy)
        switch appleScrollState {
        case .scrolling:
            return dx == 0 && dy == 0 ? [] : [event(dx, dy, .changed, .none)]
        case .idle:
            appleScrollState = .momentum
            return [event(dx, dy, .none, .began)]
        case .momentum:
            return dx == 0 && dy == 0 ? [] : [event(dx, dy, .none, .changed)]
        }
    }
}
