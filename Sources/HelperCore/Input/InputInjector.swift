#if os(macOS)
import Foundation
import LinkProtocol
import os

/// Turns `input.*` link messages into system events.
///
/// - Coordinates arrive **window-relative**; the window's frame is read at injection time, so a window that moved between
///   the touch and the injection never receives a click meant for another place. Unknown or destroyed windows drop the event.
/// - Focus follows interaction: before a button press the window is made topmost at that point (`WindowFocuser`).
/// - Everything that is pressed is remembered and released by `releaseAll()` (session end, disconnect): no stuck keys.
/// - Events are processed strictly in arrival order even though focusing and geometry lookups suspend.
public actor InputInjector {
    private let poster: any EventPoster
    private let geometry: any WindowGeometryProvider
    private let focuser: any WindowFocuser
    private let secureInput: any SecureInputProbe
    private let now: @Sendable () -> ContinuousClock.Instant
    private let onEvent: @Sendable (InputInjectorEvent) -> Void
    private let log = Logger(subsystem: "app.screon.helper", category: "input")

    /// A second raise of the same window within this interval is skipped (the window server lags behind `raise`).
    static let focusCoalesceInterval: Duration = .milliseconds(250)
    static let multiClickInterval: Duration = .milliseconds(500)
    static let multiClickDistance = 4.0

    // Serial gate.
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    // State that must be undone by `releaseAll()`.
    private var heldButtons: LinkMouseButtons = []
    private var lastGlobalPoint: LinkPoint?
    private var heldKeys: [UInt16: LinkModifiers] = [:]
    private var penInProximity = false
    private var activeGesture: (kind: LinkGestureKind, at: LinkPoint)?

    // Bookkeeping.
    private var lastRelativePoint: [WindowID: LinkPoint] = [:]
    private var lastFocus: (window: WindowID, at: ContinuousClock.Instant)?
    private var lastClick: (button: SyntheticButton, point: LinkPoint, at: ContinuousClock.Instant, count: Int)?
    private var currentClickCount = 1
    private var secureInputActive = false
    private var reportedNoPermission = false
    /// Windows the session is viewing. Input for any other window is dropped (releases excepted). Empty means nothing is allowed.
    private var authorized: Set<WindowID> = []
    /// The authorized window the keyboard is aimed at: the one the client last pressed in or focused.
    private var keyboardWindow: WindowID?
    /// Bumped by `releaseAll()`: an event that was waiting for the window server when the session ended must not be posted.
    private var epoch = 0

    public init(
        poster: any EventPoster,
        geometry: any WindowGeometryProvider,
        focuser: any WindowFocuser,
        secureInput: any SecureInputProbe,
        authorizedWindows: Set<WindowID> = [],
        now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now },
        onEvent: @escaping @Sendable (InputInjectorEvent) -> Void = { _ in }
    ) {
        self.poster = poster; self.geometry = geometry; self.focuser = focuser; self.secureInput = secureInput
        self.now = now; self.onEvent = onEvent; authorized = authorizedWindows
    }

    // MARK: Entry points

    /// Handles one message. Anything that is not an input message is ignored.
    public func handle(_ message: LinkMessage) async {
        switch message {
        case .inputPointer, .inputScroll, .inputGesture, .inputKey, .inputText: break
        default: return
        }
        await enter()
        defer { leave() }
        guard checkPermission() else { return }
        let startEpoch = epoch
        switch message {
        case .inputPointer(let event): await pointer(event, epoch: startEpoch)
        case .inputScroll(let event): await scroll(event, epoch: startEpoch)
        case .inputGesture(let event): await gesture(event, epoch: startEpoch)
        case .inputKey(let event): await key(event, epoch: startEpoch)
        case .inputText(let text): await inputText(text, epoch: startEpoch)
        default: break
        }
    }

    /// Releases every button and key that is still down and leaves the stylus proximity. Call on session end and disconnect.
    /// It never suspends, so nothing can interleave with it.
    public func releaseAll() {
        epoch += 1
        if let gesture = activeGesture {
            post(.gesture(kind: gesture.kind, phase: .cancelled, value: 0, at: gesture.at))
            activeGesture = nil
        }
        if !heldButtons.isEmpty, let point = lastGlobalPoint {
            for button in SyntheticButton.allCases where heldButtons.contains(Self.linkButton(button)) {
                post(.mouseUp(button: button, at: point, clickCount: currentClickCount, modifiers: [], pen: nil))
            }
        }
        heldButtons = []
        for keycode in heldKeys.keys.sorted() {
            post(.key(keycode: keycode, down: false, modifiers: []))
        }
        heldKeys = [:]
        if penInProximity, let point = lastGlobalPoint {
            post(.tabletProximity(entering: false, at: point))
        }
        penInProximity = false
        lastClick = nil
    }

    /// Checks `IsSecureEventInputEnabled` and reports a change. Call from a slow timer while a session is active;
    /// key and text events also check it.
    @discardableResult
    public func pollSecureInput() -> Bool {
        let enabled = secureInput.isSecureInputEnabled()
        if enabled != secureInputActive {
            secureInputActive = enabled
            onEvent(.secureInputChanged(enabled))
        }
        return enabled
    }

    /// The session calls this whenever it subscribes to or unsubscribes from a window.
    public func setAuthorizedWindows(_ windows: Set<WindowID>) {
        authorized = windows
        if let keyboardWindow, !windows.contains(keyboardWindow) { self.keyboardWindow = nil }
        lastRelativePoint = lastRelativePoint.filter { windows.contains($0.key) }
    }

    /// The client focused this window: keys and text go there. Ignored for windows that are not authorized.
    public func setKeyboardWindow(_ window: WindowID?) {
        if let window, !authorized.contains(window) { return }
        keyboardWindow = window
    }

    public var pressedButtons: LinkMouseButtons { heldButtons }
    public var pressedKeycodes: Set<UInt16> { Set(heldKeys.keys) }

    // MARK: Gate

    private func enter() async {
        if busy {
            await withCheckedContinuation { waiters.append($0) }
        } else {
            busy = true
        }
    }

    private func leave() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
    }

    // MARK: Permission

    private func checkPermission() -> Bool {
        guard poster.canPostEvents else {
            if !reportedNoPermission { reportedNoPermission = true; onEvent(.postingNotPermitted) }
            return false
        }
        reportedNoPermission = false
        return true
    }

    private func post(_ event: SyntheticEvent) {
        do { try poster.post(event) } catch { log.error("event post failed: \(String(describing: error), privacy: .private)") }
    }

    // MARK: Geometry

    private func clamp(_ point: LinkPoint, to frame: LinkRect) -> LinkPoint {
        LinkPoint(
            x: min(max(point.x, 0), frame.size.width),
            y: min(max(point.y, 0), frame.size.height)
        )
    }

    private func global(_ relative: LinkPoint, in frame: LinkRect) -> LinkPoint {
        let clamped = clamp(relative, to: frame)
        return LinkPoint(x: frame.origin.x + clamped.x, y: frame.origin.y + clamped.y)
    }

    private func usableFrame(of window: WindowID) async -> LinkRect? {
        guard let frame = await geometry.contentFrame(of: window), frame.isValid,
              frame.size.width > 0, frame.size.height > 0 else { return nil }
        return frame
    }

    // MARK: Pointer

    private static func linkButton(_ button: SyntheticButton) -> LinkMouseButtons {
        switch button {
        case .left: .left
        case .right: .right
        case .middle: .middle
        case .other: .other
        }
    }

    private static func pen(for event: LinkPointerEvent) -> PenState? {
        guard let pressure = event.pressure else { return nil }
        let tilt = event.tilt
        return PenState(
            pressure: min(max(pressure.isFinite ? pressure : 0, 0), 1),
            tiltX: min(max((tilt?.x).flatMap { $0.isFinite ? $0 : 0 } ?? 0, -1), 1),
            tiltY: min(max((tilt?.y).flatMap { $0.isFinite ? $0 : 0 } ?? 0, -1), 1)
        )
    }

    private func pointer(_ event: LinkPointerEvent, epoch startEpoch: Int) async {
        guard event.point.isValid else { return }
        let pressing = !event.buttons.subtracting(heldButtons).isEmpty
        let releasing = !heldButtons.subtracting(event.buttons).isEmpty

        let isAuthorized = authorized.contains(event.window)
        let initialFrame = isAuthorized ? await usableFrame(of: event.window) : nil
        guard startEpoch == epoch else { return }
        guard var frame = initialFrame else {
            // The window is gone. A release must still reach the system or the button stays down.
            if releasing, let point = lastGlobalPoint { applyButtonChanges(event, at: point, pen: nil) }
            return
        }

        let freshPress = pressing && heldButtons.isEmpty
        if freshPress {
            let probe = global(event.point, in: frame)
            if await focusIfNeeded(event.window, at: probe) {
                // Raising can change the stacking, and the window may have moved while we waited.
                let refreshed = await usableFrame(of: event.window)
                guard startEpoch == epoch, let refreshed else { return }
                frame = refreshed
            }
            // Coalescing may skip the raise, never this check: a press must land on the authorized window itself, not on a
            // floating window or another app that covers that point. A press that cannot be verified is dropped.
            let verified = await focuser.isFrontmost(event.window, at: global(event.point, in: frame))
            guard startEpoch == epoch, verified else { return }
        }

        let target = global(event.point, in: frame)
        lastRelativePoint[event.window] = clamp(event.point, to: frame)
        if pressing { keyboardWindow = event.window }
        let pen = Self.pen(for: event)
        if pen != nil { enterProximityIfNeeded(at: target) }

        if pressing || releasing {
            if heldButtons.isEmpty && pressing {
                post(.mouseMove(at: target, modifiers: event.modifiers, pen: pen))
            }
            applyButtonChanges(event, at: target, pen: pen)
        } else if let held = primaryHeldButton() {
            post(.mouseDrag(button: held, at: target, modifiers: event.modifiers, pen: pen))
        } else {
            post(.mouseMove(at: target, modifiers: event.modifiers, pen: pen))
        }
        if pen == nil { leaveProximityIfNeeded(at: target) }
        lastGlobalPoint = target
    }

    private func primaryHeldButton() -> SyntheticButton? {
        SyntheticButton.allCases.first { heldButtons.contains(Self.linkButton($0)) }
    }

    private func applyButtonChanges(_ event: LinkPointerEvent, at target: LinkPoint, pen: PenState?) {
        for button in SyntheticButton.allCases {
            let flag = Self.linkButton(button)
            if heldButtons.contains(flag), !event.buttons.contains(flag) {
                heldButtons.remove(flag)
                post(.mouseUp(button: button, at: target, clickCount: currentClickCount, modifiers: event.modifiers, pen: pen))
            }
        }
        for button in SyntheticButton.allCases {
            let flag = Self.linkButton(button)
            if event.buttons.contains(flag), !heldButtons.contains(flag) {
                heldButtons.insert(flag)
                currentClickCount = clickCount(for: button, at: target)
                post(.mouseDown(button: button, at: target, clickCount: currentClickCount, modifiers: event.modifiers, pen: pen))
            }
        }
    }

    private func clickCount(for button: SyntheticButton, at point: LinkPoint) -> Int {
        let instant = now()
        var count = 1
        if let last = lastClick, last.button == button, instant - last.at <= Self.multiClickInterval,
           abs(last.point.x - point.x) <= Self.multiClickDistance, abs(last.point.y - point.y) <= Self.multiClickDistance {
            count = last.count % 3 + 1
        }
        lastClick = (button, point, instant, count)
        return count
    }

    private func enterProximityIfNeeded(at point: LinkPoint) {
        guard !penInProximity else { return }
        penInProximity = true
        post(.tabletProximity(entering: true, at: point))
    }

    private func leaveProximityIfNeeded(at point: LinkPoint) {
        guard penInProximity else { return }
        penInProximity = false
        post(.tabletProximity(entering: false, at: point))
    }

    /// Raises the window unless it is already topmost at `point` or was raised a moment ago. Returns true when it was raised.
    private func focusIfNeeded(_ window: WindowID, at point: LinkPoint) async -> Bool {
        let instant = now()
        if let last = lastFocus, last.window == window, instant - last.at < Self.focusCoalesceInterval { return false }
        if await focuser.isFrontmost(window, at: point) { return false }
        await focuser.raiseAndActivate(window)
        lastFocus = (window, now())
        return true
    }

    // MARK: Scroll and gestures

    /// The place scroll and gesture events are aimed at: the last pointer position in that window, or its centre.
    private func anchor(in window: WindowID, frame: LinkRect) -> LinkPoint {
        let relative = lastRelativePoint[window] ?? LinkPoint(x: frame.size.width / 2, y: frame.size.height / 2)
        return global(relative, in: frame)
    }

    private func moveCursorIfNeeded(to target: LinkPoint, modifiers: LinkModifiers = []) {
        if lastGlobalPoint != target {
            post(.mouseMove(at: target, modifiers: modifiers, pen: nil))
            lastGlobalPoint = target
        }
    }

    private func scroll(_ event: LinkScrollEvent, epoch startEpoch: Int) async {
        guard event.dx.isFinite, event.dy.isFinite, abs(event.dx) <= LinkLimits.maxCoordinate, abs(event.dy) <= LinkLimits.maxCoordinate
        else { return }
        guard authorized.contains(event.window) else { return }
        let resolved = await usableFrame(of: event.window)
        guard startEpoch == epoch, let frame = resolved else { return }
        let target = anchor(in: event.window, frame: frame)
        // No raise for scroll: only scroll what the user can see on top. Not topmost at the anchor: drop.
        let topmost = await focuser.isFrontmost(event.window, at: target)
        guard startEpoch == epoch, topmost else { return }
        moveCursorIfNeeded(to: target)
        post(.scroll(at: target, dx: event.dx, dy: event.dy, continuous: event.continuous, phase: event.phase,
                     momentumPhase: event.momentumPhase, modifiers: []))
    }

    private func gesture(_ event: LinkGestureEvent, epoch startEpoch: Int) async {
        guard event.value.isFinite, authorized.contains(event.window) else { return }
        let resolved = await usableFrame(of: event.window)
        guard startEpoch == epoch, let frame = resolved else { return }
        let target = anchor(in: event.window, frame: frame)
        let topmost = await focuser.isFrontmost(event.window, at: target)
        guard startEpoch == epoch, topmost else { return }
        moveCursorIfNeeded(to: target)
        if poster.supportsGestures {
            post(.gesture(kind: event.kind, phase: event.phase, value: event.value, at: target))
            activeGesture = (event.phase == .began || event.phase == .changed) ? (event.kind, target) : nil
        } else if event.kind == .magnify {
            // Fallback of the design: command + scroll zooms most apps. Positive magnification zooms in.
            let lines = (event.value * 10).rounded()
            guard lines != 0 else { return }
            post(.scroll(at: target, dx: 0, dy: lines, continuous: false, phase: .none, momentumPhase: .none, modifiers: .command))
        }
    }

    // MARK: Keyboard

    /// Keys and text carry no window and go to whatever is frontmost on the Mac. Make sure that is a window of this session:
    /// otherwise bring the keyboard window forward, and if that does not work, refuse.
    private func keyboardTargetIsReady(epoch startEpoch: Int) async -> Bool {
        guard let target = keyboardWindow, authorized.contains(target) else { return false }
        if let front = await frontmostAuthorized(), front { return startEpoch == epoch }
        guard startEpoch == epoch else { return false }
        let instant = now()
        if let last = lastFocus, last.window == target, instant - last.at < Self.focusCoalesceInterval { return false }
        await focuser.raiseAndActivate(target)
        lastFocus = (target, now())
        guard startEpoch == epoch, authorized.contains(target) else { return false }
        return await frontmostAuthorized() == true && startEpoch == epoch
    }

    private func frontmostAuthorized() async -> Bool? {
        guard let front = await focuser.frontmostWindow() else { return false }
        return authorized.contains(front)
    }

    private func key(_ event: LinkKeyEvent, epoch startEpoch: Int) async {
        if event.down {
            guard await keyboardTargetIsReady(epoch: startEpoch) else { return }
            pollSecureInput() // synthetic keys are still posted: some secure fields accept them, and the banner tells the user
            heldKeys[event.keycode] = event.modifiers
            post(.key(keycode: event.keycode, down: true, modifiers: event.modifiers))
        } else if let recorded = heldKeys.removeValue(forKey: event.keycode) {
            // Only keys this session pressed are released, with the modifiers they were pressed with.
            post(.key(keycode: event.keycode, down: false, modifiers: recorded))
        }
    }

    private func inputText(_ text: String, epoch startEpoch: Int) async {
        guard text.utf8.count <= LinkLimits.maxTextInputBytes else { return }
        guard await keyboardTargetIsReady(epoch: startEpoch) else { return }
        pollSecureInput()
        for chunk in TextChunker.chunks(text) { post(.unicode(chunk)) }
    }
}
#endif
