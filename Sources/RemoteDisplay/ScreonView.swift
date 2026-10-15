#if canImport(UIKit)
import InputKit
import MetalKit
import RFBKit
import UIKit

@MainActor
public protocol ScreonViewDelegate: AnyObject {
    func screonView(_ view: ScreonView, didChangeGeometry geometry: ViewportGeometry)
}

/// View that shows the Mac screen using Metal and captures the user's input: touch, hardware keyboard, on-screen keyboard.
///
/// - Display: pinch to zoom, drag to see the off-screen part when zoomed in.
/// - Input: touch gestures are converted to mouse events by `InputKit.TouchMapper`, keys are converted to keysyms by `KeyboardState`.
/// Everything the user does leaves as protocol-neutral `InputIntent`s through `onIntents`; the owner encodes them for its protocol
/// (`RFBInputEncoder` for Screen Sharing) and sends them.
@MainActor
public final class ScreonView: MTKView, MTKViewDelegate, UIGestureRecognizerDelegate, UIKeyInput {
    public weak var geometryDelegate: ScreonViewDelegate?

    /// Receives every pointer, scroll, gesture and key intent to send to the Mac, in order.
    public var onIntents: (([InputIntent]) -> Void)?

    public private(set) var geometry = ViewportGeometry(remoteSize: .zero, viewSize: .zero)
    private var renderer: FramebufferRenderer?
    private var touchMapper = TouchMapper()
    private var keyboard = KeyboardState()
    /// Key repeat while held: iPadOS does not resend `pressesBegan` for a held key, so the view repeats it itself (see `KeyboardState.repeating`).
    private var repeatTask: Task<Void, Never>?
    private var scheduledRepeat: RepeatingKey?

    /// How gestures are interpreted. Change `mode` to switch between direct touch and trackpad.
    public var touchPolicy: TouchPolicy {
        get { touchMapper.policy }
        set { touchMapper.policy = newValue }
    }

    /// Mode for placing the Mac screen on the device. Native pixels need the number of pixels per point of the **screen currently showing the view**, so
    /// it is recomputed when the view enters a window (which may be an external display with a different scale).
    public var displayMode: DisplayMode = .default {
        didSet { if oldValue != displayMode { applyDisplayMode() } }
    }

    private func applyDisplayMode() {
        let screenScale = traitCollection.displayScale > 0 ? traitCollection.displayScale : contentScaleFactor
        preferredScaleMode = displayMode.scaleMode(screenScale: Double(screenScale))
    }

    public var preferredScaleMode: ViewportGeometry.ScaleMode = .fit {
        didSet {
            geometry.scaleMode = preferredScaleMode
            geometry.reset()
            geometryChanged()
        }
    }

    /// Whether the on-screen keyboard is shown or hidden. A hardware keyboard always works; hiding the on-screen keyboard only removes what is displayed.
    public var isSoftwareKeyboardVisible = false {
        didSet {
            guard oldValue != isSoftwareKeyboardVisible else { return }
            if !isFirstResponder { _ = becomeFirstResponder() }
            reloadInputViews()
        }
    }

    // MARK: - Initialization

    private var pinchRecognizer: UIPinchGestureRecognizer!
    private var twoFingerPanRecognizer: UIPanGestureRecognizer!
    private let emptyInputView = UIView(frame: .zero) // set as `inputView` to hide the on-screen keyboard while still receiving hardware keys

    public override init(frame: CGRect, device: MTLDevice?) {
        super.init(frame: frame, device: device ?? MTLCreateSystemDefaultDevice())
        commonInit()
    }

    public required init(coder: NSCoder) {
        super.init(coder: coder)
        device = device ?? MTLCreateSystemDefaultDevice()
        commonInit()
    }

    private func commonInit() {
        colorPixelFormat = .bgra8Unorm
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        // Draw on the display tick with the view's own `CADisplayLink` (see `requestFrame`), only when there is work: several updates arriving
        // within one tick are merged into one draw, frame spacing is more even, and when idle nothing is drawn (saves battery).
        enableSetNeedsDisplay = false
        isPaused = true
        delegate = self
        isMultipleTouchEnabled = true
        backgroundColor = .black
        // When this window's scene becomes active again (from background, a system dialog, a menu...), take keyboard focus back, otherwise the
        // hardware keyboard stops arriving. Per scene, not per app: another window of the app activating must not move focus here.
        NotificationCenter.default.addObserver(
            self, selector: #selector(sceneDidActivate(_:)), name: UIScene.didActivateNotification, object: nil
        )

        // A single accessibility element that allows direct interaction (VoiceOver does not intercept touch gestures).
        isAccessibilityElement = true
        accessibilityIdentifier = "screon"
        accessibilityLabel = tr("Remote screen")
        accessibilityTraits = .allowsDirectInteraction

        if let device {
            renderer = try? FramebufferRenderer(device: device, colorPixelFormat: colorPixelFormat)
            renderer?.setCursor(.defaultArrow) // used temporarily until the server sends the real cursor image
        }

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))

        let twoFingerTap = UITapGestureRecognizer(target: self, action: #selector(handleTwoFingerTap(_:)))
        twoFingerTap.numberOfTouchesRequired = 2

        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        longPress.minimumPressDuration = 0.35

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.minimumNumberOfTouches = 1
        pan.maximumNumberOfTouches = 1
        pan.require(toFail: longPress) // long press first means drag and drop; moving right away means a plain drag

        twoFingerPanRecognizer = UIPanGestureRecognizer(target: self, action: #selector(handleTwoFingerPan(_:)))
        twoFingerPanRecognizer.minimumNumberOfTouches = 2
        twoFingerPanRecognizer.maximumNumberOfTouches = 2

        pinchRecognizer = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        rotationRecognizer = UIRotationGestureRecognizer(target: self, action: #selector(handleRotation(_:)))

        // Finger gestures accept fingers only: the pencil and mouse have their own recognizers below, with different semantics (absolute, immediate).
        let fingers = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        for recognizer in [tap, twoFingerTap, longPress, pan, twoFingerPanRecognizer!, pinchRecognizer!, rotationRecognizer!] {
            recognizer.allowedTouchTypes = fingers
            recognizer.delegate = self
            addGestureRecognizer(recognizer)
        }

        // Apple Pencil: receive the raw stroke from the moment the tip touches (0-second hold); `PencilGesture` classifies tap, drag, hold.
        let pencilRecognizer = UILongPressGestureRecognizer(target: self, action: #selector(handlePencil(_:)))
        pencilRecognizer.minimumPressDuration = 0
        pencilRecognizer.allowableMovement = .greatestFiniteMagnitude
        pencilRecognizer.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.pencil.rawValue)]

        // Mouse and trackpad attached to the iPad (needs `UIApplicationSupportsIndirectInputEvents`): a click presses immediately, like a real mouse.
        let indirect = [NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
        let primaryMouse = UILongPressGestureRecognizer(target: self, action: #selector(handleMouseButton(_:)))
        primaryMouse.minimumPressDuration = 0
        primaryMouse.allowableMovement = .greatestFiniteMagnitude
        primaryMouse.allowedTouchTypes = indirect
        // Right button: only a tap recognizer can select the button (`buttonMaskRequired`), so the right button is a click, not a drag.
        let secondaryMouse = UITapGestureRecognizer(target: self, action: #selector(handleSecondaryClick(_:)))
        secondaryMouse.buttonMaskRequired = .secondary
        secondaryMouse.allowedTouchTypes = indirect

        // Hover without a click (and a pencil hovering on supported iPads): move the Mac pointer along.
        hoverRecognizer = UIHoverGestureRecognizer(target: self, action: #selector(handleHover(_:)))
        // Mouse wheel, two fingers on the trackpad: only scroll events are accepted, no touches.
        wheelRecognizer = UIPanGestureRecognizer(target: self, action: #selector(handleWheel(_:)))
        wheelRecognizer.allowedScrollTypesMask = .all
        wheelRecognizer.allowedTouchTypes = []

        for recognizer in [pencilRecognizer, primaryMouse, secondaryMouse, hoverRecognizer!, wheelRecognizer!] {
            recognizer.delegate = self
            addGestureRecognizer(recognizer)
        }
        addInteraction(UIPointerInteraction(delegate: self))
        addInteraction(UIPencilInteraction(delegate: self))

        // When this window's scene deactivates (backgrounding, focus moving to another window), release all keys and mouse buttons so the Mac is
        // not left stuck (for example Command never released). Per scene, so one window going inactive does not release input in another.
        NotificationCenter.default.addObserver(
            self, selector: #selector(sceneWillDeactivate(_:)), name: UIScene.willDeactivateNotification, object: nil
        )
    }

    // MARK: - Data from the session

    /// Uploads a new frame to the GPU and requests a draw.
    public func display(_ framebuffer: Framebuffer, dirty: [PixelRect]? = nil) {
        updatesSincePresent += 1
        renderer?.upload(framebuffer, dirty: dirty)
        let size = CGSize(width: framebuffer.width, height: framebuffer.height)
        if geometry.remoteSize != size {
            geometry.updateRemoteSize(size)
            geometryChanged() // notify both the delegate and the accessibility value (the displayed size changes with the Mac size)
        }
        requestFrame()
    }

    /// Sets the cursor image sent by the server. Apple's server separates the cursor from the screen image, so we have to draw it ourselves.
    /// An empty image means the server hides the cursor.
    public func setCursor(_ cursor: CursorImage) {
        renderer?.setCursor(cursor)
        requestFrame()
    }

    // MARK: - Draw tick

    private var displayLink: CADisplayLink?
    private var needsFrame = false
    private var idleTicks = 0
    private var updatesSincePresent = 0

    /// A frame with new content was just drawn: time (seconds, `CACurrentMediaTime` clock) and the number of updates merged into it.
    /// Used for smoothness metrics.
    public var onContentPresented: ((CFTimeInterval, Int) -> Void)?

    /// Requests a draw on the next display tick. Calling it several times within one tick draws only once.
    public func requestFrame() {
        needsFrame = true
        idleTicks = 0
        displayLink?.isPaused = false
    }

    private func startDisplayLink() {
        guard displayLink == nil else { return }
        // The proxy holds the view weakly: `CADisplayLink` strongly retains its target, so retaining the view directly would never free it.
        let link = CADisplayLink(target: DisplayLinkProxy(self), selector: #selector(DisplayLinkProxy.tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 120, preferred: 120)
        link.isPaused = !needsFrame
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    fileprivate func displayLinkTick(_ link: CADisplayLink) {
        if momentum.isActive {
            stepMomentum(link)
            idleTicks = 0
            if !needsFrame { return } // Mac scroll momentum needs no frame redraw; panning the viewport already requested one
        }
        guard needsFrame else {
            // Two consecutive ticks with no work: pause; the next `requestFrame()` wakes it again.
            idleTicks += 1
            if idleTicks >= 2 { link.isPaused = true }
            return
        }
        needsFrame = false
        let merged = updatesSincePresent
        updatesSincePresent = 0
        draw()
        if merged > 0 { onContentPresented?(link.targetTimestamp, merged) }
    }

    /// `false` when the server draws the cursor into the frame (the app does not ask for a separate cursor image): drawing an extra arrow locally would make two cursors.
    public var drawsLocalCursor = true {
        didSet { requestFrame() }
    }

    /// Opts out of iPadOS text-editing gestures (three fingers for undo, copy, paste): this view receives keys but is not a text field,
    /// and those gestures would swallow the three-finger touch meant for the Mac screen.
    public override var editingInteractionConfiguration: UIEditingInteractionConfiguration { .none }

    /// Whether to draw the Mac's cursor. The cursor sits at the last position we sent: RFB does not report when the Mac's real mouse moves.
    public var showsRemoteCursor = true {
        didSet { requestFrame() }
    }

    // MARK: - Layout and drawing

    /// Viewport size in **device pixels** each time it changes (rotation, Split View, Stage Manager). Used for the "match device
    /// resolution" mode, where Apple's server shrinks the image to exactly this size.
    public var onPixelSizeChange: ((CGSize) -> Void)?
    private var lastReportedPixelSize = CGSize.zero

    public var pixelSize: CGSize {
        let scale = traitCollection.displayScale > 0 ? traitCollection.displayScale : contentScaleFactor
        return CGSize(width: bounds.width * scale, height: bounds.height * scale)
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        geometry.updateViewSize(bounds.size)
        geometryChanged()
        let size = pixelSize
        if size != lastReportedPixelSize, size.width > 0, size.height > 0 {
            lastReportedPixelSize = size
            onPixelSizeChange?(size)
        }
    }

    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    public func draw(in view: MTKView) {
        guard let renderer,
              let pass = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let buffer = renderer.makeCommandBuffer() else { return }
        let pointer = (showsRemoteCursor && drawsLocalCursor && touchMapper.hasPointer) ? touchMapper.pointer : nil
        renderer.encode(
            into: buffer, pass: pass, geometry: geometry, deviceScale: Double(view.contentScaleFactor), pointer: pointer
        )
        buffer.present(drawable)
        buffer.commit()
    }

    private func geometryChanged() {
        requestFrame()
        // Tell VoiceOver (and UI tests) what size the Mac screen is shown at.
        let shown = geometry.contentRect
        accessibilityValue = tr(
            "Mac screen %lld×%lld, shown at %lld×%lld points",
            Int(geometry.remoteSize.width), Int(geometry.remoteSize.height),
            Int(shown.width.rounded()), Int(shown.height.rounded()))
        geometryDelegate?.screonView(self, didChangeGeometry: geometry)
    }

    /// The viewport is smaller than the content in at least one dimension, so it can be dragged to see the hidden part.
    private var isZoomed: Bool {
        let content = geometry.contentRect
        return content.width > bounds.width + 0.5 || content.height > bounds.height + 0.5
    }

    // MARK: - Touch gestures

    /// `false` in view-only mode: gestures do not control the Mac and the drawn cursor does not move (previously it still followed the finger,
    /// to where the Mac's real cursor never went). Dragging still pans the viewport when zoomed in, and pinching still zooms.
    public var acceptsRemoteInput = true {
        didSet { if !acceptsRemoteInput, oldValue { releaseAllInput() } }
    }

    private func dispatch(_ event: TouchEvent) {
        guard acceptsRemoteInput else {
            switch event {
            case .pan(_, let translation, _), .twoFingerPan(_, let translation, _):
                geometry.pan(by: translation)
                geometryChanged()
            default:
                break
            }
            return
        }
        let output = touchMapper.handle(event, in: geometry, isZoomed: isZoomed)
        if !output.intents.isEmpty {
            onIntents?(output.intents)
            requestFrame() // the cursor may have moved
            // A modifier latched once (tapping ⌘ on the sidebar or accessory bar) applies to ONE action only: previously it was released only after
            // a key, so after a ⌘-click it stayed down and the next typed key became an unintended ⌘ combination. A locked modifier stays.
            if PointerActions.completesAButtonAction(output.intents, previousButtons: &lastSentButtons) {
                let release = modifierKeys.actionCompleted()
                if !release.isEmpty { onIntents?(release) }
            }
        }
        if let pan = output.viewportPan {
            geometry.pan(by: pan)
            geometryChanged()
        }
    }

    /// Mouse buttons (left, middle, right) last sent, to know when a click or a drag has just finished.
    private var lastSentButtons: PointerButtons = []

    private func phase(of recognizer: UIGestureRecognizer) -> GesturePhase {
        switch recognizer.state {
        case .began: .began
        case .changed: .changed
        default: .ended
        }
    }

    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        guard !limitsFingers else { return }
        // Two consecutive taps are two clicks; macOS recognizes a double click by time and position itself.
        dispatch(.tap(recognizer.location(in: self), count: 1))
    }

    @objc private func handleTwoFingerTap(_ recognizer: UITapGestureRecognizer) {
        guard !limitsFingers else { return }
        dispatch(.twoFingerTap(recognizer.location(in: self)))
    }

    @objc private func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
        guard !limitsFingers else { return }
        dispatch(.longPress(recognizer.location(in: self), phase(of: recognizer)))
    }

    @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
        let translation = recognizer.translation(in: self)
        recognizer.setTranslation(.zero, in: self) // send the incremental distance, not a running total
        let location = recognizer.location(in: self)
        if limitsFingers {
            // Pencil has been used and "fingers only scroll" is chosen: a one-finger drag scrolls (or pans the viewport when zoomed), like Sidecar.
            dispatch(.twoFingerPan(location: location, translation: translation, phase(of: recognizer)))
            return
        }
        dispatch(.pan(location: location, translation: translation, phase(of: recognizer)))
    }

    // MARK: Apple Pencil, iPad mouse and trackpad

    private var pencil = PencilGesture()
    private var hasSeenPencil = false
    private var hoverRecognizer: UIHoverGestureRecognizer!
    private var wheelRecognizer: UIPanGestureRecognizer!

    /// "Fingers only scroll when using the pencil" (like Sidecar): after the first pencil stroke, fingers only scroll and zoom, taps do not click.
    public var fingersOnlyScrollWithPencil = false

    /// Double tap on Apple Pencil (2nd generation, Pro). The app chooses what to do.
    public var onPencilDoubleTap: (() -> Void)?

    private var limitsFingers: Bool { fingersOnlyScrollWithPencil && hasSeenPencil }

    @objc private func handlePencil(_ recognizer: UILongPressGestureRecognizer) {
        hasSeenPencil = true
        stopMomentum()
        let point = recognizer.location(in: self)
        let time = CACurrentMediaTime()
        let actions: [PencilAction] = switch recognizer.state {
        case .began: pencil.began(at: point, time: time)
        case .changed: pencil.moved(to: point, time: time)
        case .ended: pencil.ended(at: point, time: time)
        default: pencil.cancelled()
        }
        for action in actions { dispatch(.pencil(action)) }
    }

    @objc private func handleMouseButton(_ recognizer: UILongPressGestureRecognizer) {
        stopMomentum()
        dispatch(.mouseButton(recognizer.location(in: self), .primary, phase(of: recognizer)))
    }

    @objc private func handleSecondaryClick(_ recognizer: UITapGestureRecognizer) {
        stopMomentum()
        let location = recognizer.location(in: self)
        dispatch(.mouseButton(location, .secondary, .began))
        dispatch(.mouseButton(location, .secondary, .ended))
    }

    @objc private func handleHover(_ recognizer: UIHoverGestureRecognizer) {
        guard recognizer.state == .began || recognizer.state == .changed else { return }
        dispatch(.hover(recognizer.location(in: self)))
    }

    @objc private func handleWheel(_ recognizer: UIPanGestureRecognizer) {
        let translation = recognizer.translation(in: self)
        recognizer.setTranslation(.zero, in: self)
        let location = recognizer.location(in: self)
        let phase = phase(of: recognizer)
        if phase == .began { stopMomentum() }
        dispatch(.scroll(location: location, translation: translation, phase))
        // Trackpad: lifting two fingers mid-swipe keeps scrolling, like on a Mac. A (discrete) mouse wheel has almost no velocity.
        if recognizer.state == .ended, momentum.start(velocity: recognizer.velocity(in: self), at: location) {
            momentumIsWheel = true
            lastMomentumTick = nil
            requestFrame()
        }
    }

    /// Right click at the current pointer position (for example on a double tap of the pencil).
    public func secondaryClickAtPointer() {
        dispatch(.secondaryClickAtPointer)
    }

    @objc private func handleTwoFingerPan(_ recognizer: UIPanGestureRecognizer) {
        let translation = recognizer.translation(in: self)
        recognizer.setTranslation(.zero, in: self)
        let location = recognizer.location(in: self)
        let phase = phase(of: recognizer)
        if phase == .began { stopMomentum() }
        if isSendingMacGesture {
            // Pinching/rotating on the Mac: a real trackpad does not scroll and pinch at once. Close the open scroll (if any) then ignore.
            if scrollOpen { dispatch(.twoFingerPan(location: location, translation: .zero, .ended)) }
            scrollOpen = false
            return
        }
        scrollOpen = phase != .ended
        dispatch(.twoFingerPan(location: location, translation: translation, phase))
        // Lifting off mid-swipe: keep scrolling and slow down like a trackpad (only when the gesture ends normally, not when cancelled).
        if recognizer.state == .ended, momentum.start(velocity: recognizer.velocity(in: self), at: location) {
            momentumIsWheel = false
            lastMomentumTick = nil
            requestFrame()
        }
    }

    // MARK: Momentum

    private var momentum = MomentumScroller()
    private var lastMomentumTick: CFTimeInterval?
    /// Momentum comes from the iPad trackpad (always scrolls the Mac), not from two fingers on the screen.
    private var momentumIsWheel = false

    /// A momentum step goes through the same path as the gesture that produced it.
    private func momentumEvent(_ translation: CGPoint, _ phase: GesturePhase) -> TouchEvent {
        momentumIsWheel
            ? .scroll(location: momentum.location, translation: translation, phase)
            : .twoFingerPan(location: momentum.location, translation: translation, phase)
    }

    private func stopMomentum() {
        guard momentum.isActive else { return }
        momentum.stop()
        dispatch(momentumEvent(.zero, .ended))
    }

    /// One momentum step per display tick, going through the same path as the two-finger gesture (scroll ticks, or panning the viewport when zoomed).
    private func stepMomentum(_ link: CADisplayLink) {
        let seconds = lastMomentumTick.map { link.targetTimestamp - $0 } ?? link.duration
        lastMomentumTick = link.targetTimestamp
        let travelled = momentum.advance(by: seconds)
        dispatch(momentumEvent(travelled, .changed))
        if !momentum.isActive {
            dispatch(momentumEvent(.zero, .ended))
        }
    }

    private var pinchStartZoom = 1.0
    private var lastPinchScale = 1.0
    private var lastRotation = 0.0
    private var rotationRecognizer: UIRotationGestureRecognizer!
    /// The two-finger scroll currently open (began sent, ended not yet sent).
    private var scrollOpen = false

    /// "Pinch/rotate: send to Mac" (Apple server only, message 23): pinch becomes zoom on the Mac, rotate becomes rotate. When off, pinch zooms
    /// the viewport on the iPad as before, and rotate does nothing.
    public var pinchSendsToMac = false

    private var isSendingMacGesture: Bool {
        guard pinchSendsToMac else { return false }
        let active: (UIGestureRecognizer?) -> Bool = { $0?.state == .began || $0?.state == .changed }
        return active(pinchRecognizer) || active(rotationRecognizer)
    }

    @objc private func handleRotation(_ recognizer: UIRotationGestureRecognizer) {
        guard pinchSendsToMac, acceptsRemoteInput else { return }
        let phase = phase(of: recognizer)
        if phase == .began { lastRotation = 0 }
        let radians = Double(recognizer.rotation)
        // UIKit: radians, positive clockwise. NSEvent: degrees, positive counterclockwise.
        let degrees = -(radians - lastRotation) * 180 / .pi
        dispatch(.rotate(location: recognizer.location(in: self), degrees: degrees, phase))
        lastRotation = radians
    }

    @objc private func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
        if pinchSendsToMac, acceptsRemoteInput {
            // Sent to the Mac: each step is the scale change since the previous step, like `NSEvent.magnification`.
            let phase = phase(of: recognizer)
            if phase == .began { lastPinchScale = 1 }
            let scale = Double(recognizer.scale)
            dispatch(.magnify(location: recognizer.location(in: self), scaleDelta: scale - lastPinchScale, phase))
            lastPinchScale = scale
            return
        }
        switch recognizer.state {
        case .began:
            pinchStartZoom = geometry.zoom
        case .changed:
            geometry.setZoom(pinchStartZoom * Double(recognizer.scale), around: recognizer.location(in: self))
            geometryChanged()
        default:
            break
        }
    }

    /// Region (window coordinates) where the view does not accept gestures, because a floating control (the toolbar) sits on top of it.
    ///
    /// This view's gestures sit deeper in the view tree so they beat the SwiftUI button above and CANCEL it: tapping the button does
    /// nothing, and the touch becomes a click on the Mac screen right under the button. With a real Mac, pressing "Disconnect" would
    /// mistakenly click whatever lies under the toolbar.
    public var excludedRegions: [CGRect] = []

    public func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        // Multi-finger gestures are not blocked: a stray finger resting on the toolbar should not break the whole gesture.
        // (The XCUITest `twoFingerTap()` places two fingers almost a full screen height apart, and one lands on the toolbar.)
        let isMultiTouch = gestureRecognizer === pinchRecognizer || gestureRecognizer === twoFingerPanRecognizer
            || gestureRecognizer === rotationRecognizer
            || ((gestureRecognizer as? UITapGestureRecognizer)?.numberOfTouchesRequired ?? 1) > 1
        if isMultiTouch { return true }
        let point = touch.location(in: nil)
        return !excludedRegions.contains { $0.contains(point) }
    }

    public func gestureRecognizer(_ gesture: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        // Pinch and two-finger drag happen together (zooming and panning at once). Hover blocks nothing (and nothing blocks it).
        // Other gestures are mutually exclusive.
        if gesture === hoverRecognizer || other === hoverRecognizer { return true }
        // Pinch, rotate and two-finger drag work together (when sending to the Mac, scrolling pauses during pinch/rotate: see `handleTwoFingerPan`).
        let twoFinger: [UIGestureRecognizer?] = [pinchRecognizer, rotationRecognizer, twoFingerPanRecognizer]
        return twoFinger.contains { $0 === gesture } && twoFinger.contains { $0 === other }
    }

    // MARK: - Keyboard

    public override var canBecomeFirstResponder: Bool { true }

    public override var inputView: UIView? { isSoftwareKeyboardVisible ? nil : emptyInputView }

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { startDisplayLink() } else { stopDisplayLink() }
        if window != nil, displayMode == .native { applyDisplayMode() } // the pixel scale of the screen just entered
        if window != nil { _ = becomeFirstResponder() } // must be first responder to receive hardware keys
    }

    /// iPadOS keeps Escape for itself (closing floating windows, cancelling...) so it never reaches `pressesBegan`: measured on a real iPad
    /// and the simulator, a typed Escape is not seen by the server. A key command with priority over the system does receive it.
    public override var keyCommands: [UIKeyCommand]? {
        let escape = UIKeyCommand(action: #selector(escapePressed), input: UIKeyCommand.inputEscape, modifierFlags: [])
        escape.wantsPriorityOverSystemBehavior = true
        // ⌘F is the iPadOS system "Find" so it never reaches `pressesBegan` (measured on the iPad simulator); the remote Mac needs it for Safari, editors...
        let find = UIKeyCommand(action: #selector(commandChordPressed(_:)), input: "f", modifierFlags: .command)
        find.wantsPriorityOverSystemBehavior = true
        return [escape, find]
    }

    @objc private func escapePressed() {
        onIntents?(VirtualKey.escape.tap + modifierKeys.actionCompleted())
    }

    @objc private func commandChordPressed(_ sender: UIKeyCommand) {
        let commandDown = keyboard.isHolding(keysym: KeysymMapper.commandLeft) || keyboard.isHolding(keysym: KeysymMapper.commandRight)
            || modifierKeys.active.contains(.command)
        guard let input = sender.input, let character = input.first,
              let chord = KeysymMapper.commandChord(character, commandAlreadyDown: commandDown) else { return }
        onIntents?(chord + modifierKeys.actionCompleted())
    }

    /// Keyboard focus lost (a menu or another window took it): the release of a held key will arrive elsewhere, so release now,
    /// including stopping key repeat. Otherwise the Mac sees a stuck key, or Backspace repeating forever.
    public override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned {
            let messages = keyboard.releaseAll()
            updateKeyRepeat()
            if !messages.isEmpty { onIntents?(messages) }
        }
        return resigned
    }

    @objc private func sceneDidActivate(_ notification: Notification) {
        guard isOwnScene(notification) else { return }
        reclaimKeyboardFocus()
    }

    @objc private func sceneWillDeactivate(_ notification: Notification) {
        guard isOwnScene(notification) else { return }
        releaseAllInput()
    }

    /// Whether a scene notification is about the scene this view lives in.
    private func isOwnScene(_ notification: Notification) -> Bool {
        guard let scene = notification.object as? UIScene, let own = window?.windowScene else { return false }
        return scene === own
    }

    @objc private func reclaimKeyboardFocus() {
        if window != nil, !isFirstResponder { _ = becomeFirstResponder() }
    }

    /// Touching the screen also reclaims keyboard focus: a SwiftUI control that was just used may have taken it.
    public override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        reclaimKeyboardFocus()
        stopMomentum() // touching again stops immediately, like scrolling on a trackpad
        super.touchesBegan(touches, with: event)
    }

    /// Hardware keyboard: each key press/release is converted to a keysym.
    public override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if !handle(presses, isDown: true) { super.pressesBegan(presses, with: event) }
    }

    public override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if !handle(presses, isDown: false) { super.pressesEnded(presses, with: event) }
    }

    public override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if !handle(presses, isDown: false) { super.pressesCancelled(presses, with: event) }
    }

    private func handle(_ presses: Set<UIPress>, isDown: Bool) -> Bool {
        var messages: [InputIntent] = []
        var handled = false
        var releasedAPlainKey = false
        for press in presses {
            guard let key = press.key else { continue }
            var modifiers: KeyModifiers = []
            if key.modifierFlags.contains(.shift) { modifiers.insert(.shift) }
            if key.modifierFlags.contains(.control) { modifiers.insert(.control) }
            if key.modifierFlags.contains(.alternate) { modifiers.insert(.option) }
            if key.modifierFlags.contains(.command) { modifiers.insert(.command) }

            let result = keyboard.handle(KeyPress(
                hidUsage: key.keyCode.rawValue, characters: key.characters,
                charactersIgnoringModifiers: key.charactersIgnoringModifiers, modifiers: modifiers, isDown: isDown
            ))
            if !result.isEmpty { handled = true }
            messages += result
            if !isDown, !result.isEmpty, !(0xE0...0xE7).contains(key.keyCode.rawValue) { releasedAPlainKey = true }
        }
        // A modifier latched on the sidebar or accessory bar is released after the regular key is released, so the order is Cmd↓ c↓ c↑ Cmd↑.
        if releasedAPlainKey { messages += modifierKeys.actionCompleted() }
        if !messages.isEmpty { onIntents?(messages) }
        updateKeyRepeat()
        return handled
    }

    /// Starts, changes or stops key repeat according to `keyboard.repeating`. After the initial delay, resends the press steadily until
    /// the key is released (or another key is pressed). Sends only "press", no "release" in between, exactly like a real keyboard's repeat.
    private func updateKeyRepeat() {
        guard keyboard.repeating != scheduledRepeat else { return }
        repeatTask?.cancel()
        repeatTask = nil
        scheduledRepeat = keyboard.repeating
        guard let key = scheduledRepeat else { return }
        repeatTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: KeyRepeat.initialDelay)
            let stopAt = ContinuousClock.now + KeyRepeat.maximumDuration
            // Do not hold `self` across the sleep: the view may have been destroyed.
            while !Task.isCancelled, ContinuousClock.now < stopAt, self?.repeatOnce(key) == true {
                try? await Task.sleep(for: KeyRepeat.interval)
            }
        }
    }

    /// Sends one repeat if `key` is still the held key. Returns `false` when it should stop.
    private func repeatOnce(_ key: RepeatingKey) -> Bool {
        guard keyboard.repeating == key else { return false }
        onIntents?([.key(key.keysym, isDown: true)])
        return true
    }

    /// Releases every held key and mouse button. Call on backgrounding, focus loss or disconnect.
    @objc public func releaseAllInput() {
        momentum.stop()
        let messages = keyboard.releaseAll() + modifierKeys.releaseAll() + touchMapper.releaseAll()
        updateKeyRepeat()
        if !messages.isEmpty { onIntents?(messages) }
    }

    // MARK: Modifier keys (sidebar, accessory bar)

    /// Modifier keys currently down on the Mac from the sidebar or accessory bar (held, latched once, locked). When they change, `onModifierStatesChange`
    /// is called.
    public private(set) var modifierKeys = ModifierKeys() {
        didSet {
            if oldValue != modifierKeys { onModifierStatesChange?(modifierKeys.states) }
        }
    }

    public var onModifierStatesChange: (([StickyModifier: ModifierState]) -> Void)?

    /// A finger rests on a sidebar modifier key: press immediately on the Mac (to ⌘-click with the other hand).
    public func modifierTouchDown(_ modifier: StickyModifier) {
        let messages = modifierKeys.touchDown(modifier, at: CACurrentMediaTime())
        if !messages.isEmpty { onIntents?(messages) }
    }

    /// Finger lifted from a modifier key: release, or become latched once if it was a short tap.
    public func modifierTouchUp(_ modifier: StickyModifier) {
        let messages = modifierKeys.touchUp(modifier, at: CACurrentMediaTime())
        if !messages.isEmpty { onIntents?(messages) }
    }

    /// Tap a modifier key on the accessory bar: latch once; two quick taps lock; tapping while latched or locked drops it.
    public func toggleModifier(_ modifier: StickyModifier) {
        let messages = modifierKeys.tap(modifier, at: CACurrentMediaTime())
        if !messages.isEmpty { onIntents?(messages) }
    }

    /// Releases every modifier key of the sidebar and accessory bar (for example when hiding the sidebar: a locked key must not stay stuck without being visible).
    public func releaseModifiers() {
        let messages = modifierKeys.releaseAll()
        if !messages.isEmpty { onIntents?(messages) }
    }

    /// Press a key on the accessory bar or sidebar. A modifier latched once is released right after.
    public func press(_ key: VirtualKey) {
        onIntents?(key.tap + modifierKeys.actionCompleted())
    }

    /// ⌘ plus a letter (the sidebar's Undo button is ⌘Z). Do not press ⌘ again if it is held or locked: the second release would make
    /// the Mac see ⌘ released while the sidebar still reports it held. Other latched modifiers still apply (latched ⇧ + Undo = ⌘⇧Z).
    public func pressCommandChord(_ character: Character) {
        let commandDown = modifierKeys.active.contains(.command)
        guard let chord = KeysymMapper.commandChord(character, commandAlreadyDown: commandDown) else { return }
        onIntents?(chord + modifierKeys.actionCompleted())
    }

    // MARK: UIKeyInput (on-screen keyboard)

    public var hasText: Bool { true }

    public func insertText(_ text: String) {
        let typed = KeyboardState.typing(text)
        guard !typed.isEmpty else { return }
        onIntents?(typed + modifierKeys.actionCompleted()) // a latched Ctrl/Cmd applies only to this character
    }

    public func deleteBackward() {
        onIntents?(InputIntent.tap(0xFF08, macKeyCode: 51) + modifierKeys.actionCompleted()) // Backspace
    }

    // Turn off autocorrect and autocapitalization: text goes straight to the Mac, which is where it gets processed.
    public var autocorrectionType: UITextAutocorrectionType = .no
    public var autocapitalizationType: UITextAutocapitalizationType = .none
    public var spellCheckingType: UITextSpellCheckingType = .no
    public var smartQuotesType: UITextSmartQuotesType = .no
    public var smartDashesType: UITextSmartDashesType = .no
}
/// Target of `CADisplayLink`, holding the view weakly (the display link strongly retains its target).
private final class DisplayLinkProxy: NSObject {
    private weak var view: ScreonView?

    init(_ view: ScreonView) {
        self.view = view
    }

    @MainActor @objc func tick(_ link: CADisplayLink) {
        guard let view else {
            link.invalidate()
            return
        }
        view.displayLinkTick(link)
    }
}

// MARK: - iPad pointer, pencil double tap

extension ScreonView: UIPointerInteractionDelegate, UIPencilInteractionDelegate {
    /// Hides the iPad's round pointer over the Mac screen: the Mac's cursor (drawn locally or by the server) already follows the mouse, and two
    /// overlapping cursors would only confuse. In view-only mode or with the Mac cursor off, keep the iPad pointer so you can tell where the mouse is.
    public func pointerInteraction(_ interaction: UIPointerInteraction, styleFor region: UIPointerRegion) -> UIPointerStyle? {
        acceptsRemoteInput && showsRemoteCursor ? .hidden() : nil
    }

    public func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveTap tap: UIPencilInteraction.Tap) {
        guard acceptsRemoteInput else { return }
        onPencilDoubleTap?()
    }
}
#endif
