import InputKit
import LinkProtocol
import MetalKit
import RemoteDisplay
import RFBKit
import UIKit
import WindowKit

/// Shows one Mac window of App Mode with Metal and turns touch, pencil, mouse, trackpad, hardware keyboard and the iPad's input methods
/// into protocol-neutral `InputIntent`s in **window coordinates** (Mac points relative to the window's content origin).
///
/// - Drawing: the decoded video goes through `VideoWindowRenderer` (the window is a sub-rectangle of the coded frame), child surfaces
///   are drawn over it, and the Mac cursor is drawn locally from `cursor.shape` pictures.
/// - Geometry: `ViewportGeometry` draws and zooms; `WindowCoordinateSpace` is built from it for input, so what is touched is what is seen.
/// - Text: the view is a (minimal) `UITextInput`, so an input method such as Vietnamese Telex composes in the iPad's own keyboard and only
///   the final characters leave as one `.text` intent.
@MainActor
final class AppWindowView: MTKView, MTKViewDelegate, UIGestureRecognizerDelegate, UITextInput {
    /// Intents to send to the Mac, in order.
    var onIntents: (([InputIntent]) -> Void)?
    /// The view's size in device pixels, whenever it changes (to ask the Mac for a stream of that size).
    var onViewPixelSize: ((CGSize) -> Void)?

    var stream: WindowStream? {
        didSet {
            guard stream !== oldValue else { return }
            lastLayout = nil
            lastCursorVersion = -1
            oldValue?.setWakeHandler(nil)
            stream?.setWakeHandler { [weak self] in DispatchQueue.main.async { self?.requestFrame() } }
            requestFrame()
        }
    }

    /// How the window is laid into the view.
    var fitMode: WindowFitMode = .fit {
        didSet {
            guard oldValue != fitMode else { return }
            lastLayout = nil
            geometry.reset()
            requestFrame()
        }
    }

    /// False in view-only situations (for example while the connection is down): gestures only move the picture.
    var acceptsRemoteInput = true {
        didSet { if !acceptsRemoteInput, oldValue { releaseAllInput() } }
    }

    var touchPolicy: TouchPolicy {
        get { touchMapper.policy }
        set { touchMapper.policy = newValue }
    }

    var isSoftwareKeyboardVisible = false {
        didSet {
            guard oldValue != isSoftwareKeyboardVisible else { return }
            if !isFirstResponder { _ = becomeFirstResponder() }
            reloadInputViews()
        }
    }

    // MARK: State

    private var renderer: VideoWindowRenderer?
    private(set) var geometry = ViewportGeometry(remoteSize: .zero, viewSize: .zero)
    private var lastLayout: WindowStreamLayout?
    private var lastCursorVersion = -1
    private var touchMapper = TouchMapper()
    private var router = InputRouter()
    private var keyboard = KeyboardState()
    private var pencil = PencilGesture()
    private var momentum = MomentumScroller()
    private var lastMomentumTick: CFTimeInterval?
    private var momentumIsWheel = false
    private var repeatTask: Task<Void, Never>?
    private var scheduledRepeat: RepeatingKey?
    private var pinchStartZoom = 1.0
    private var mouseButtons: PointerButtons = []
    private var children: [SurfaceID: (surface: BGRAImageSurface, offset: LinkPoint)] = [:]
    private let emptyInputView = UIView(frame: .zero)
    private var lastReportedPixelSize = CGSize.zero

    // Composition state of the text input: the "document" is only the marked text, which stays local until it is committed.
    private var composing = ""
    private var composingSelection = NSRange(location: 0, length: 0)

    // MARK: Setup

    override init(frame: CGRect, device: MTLDevice?) {
        super.init(frame: frame, device: device ?? MTLCreateSystemDefaultDevice())
        commonInit()
    }

    required init(coder: NSCoder) {
        super.init(coder: coder)
        device = device ?? MTLCreateSystemDefaultDevice()
        commonInit()
    }

    private func commonInit() {
        colorPixelFormat = .bgra8Unorm
        clearColor = MTLClearColor(red: 0.08, green: 0.08, blue: 0.09, alpha: 1)
        enableSetNeedsDisplay = false
        isPaused = true
        delegate = self
        isMultipleTouchEnabled = true
        backgroundColor = .black
        if let device {
            renderer = try? VideoWindowRenderer(device: device, colorPixelFormat: colorPixelFormat)
            renderer?.setCursor(.defaultArrow)
        }
        isAccessibilityElement = true
        accessibilityIdentifier = "remote-window"
        accessibilityLabel = String(localized: "Mac window")
        accessibilityTraits = .allowsDirectInteraction

        NotificationCenter.default.addObserver(self, selector: #selector(sceneDidActivate(_:)), name: UIScene.didActivateNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(sceneWillDeactivate(_:)), name: UIScene.willDeactivateNotification, object: nil)
        installGestures()
        addInteraction(UIPointerInteraction(delegate: self))
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    // MARK: Draw tick

    private var displayLink: CADisplayLink?
    private var needsFrame = false
    private var idleTicks = 0

    func requestFrame() {
        needsFrame = true
        idleTicks = 0
        displayLink?.isPaused = false
    }

    private func startDisplayLink() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: LinkProxy(self), selector: #selector(LinkProxy.tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 120, preferred: 120)
        link.isPaused = !needsFrame
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    fileprivate func tick(_ link: CADisplayLink) {
        if momentum.isActive {
            stepMomentum(link)
            idleTicks = 0
        }
        guard needsFrame else {
            idleTicks += 1
            if idleTicks >= 2 { link.isPaused = true }
            return
        }
        needsFrame = false
        prepareFrame()
        draw()
    }

    /// Brings the renderer up to date with what the stream has received since the last tick.
    private func prepareFrame() {
        guard let stream, let renderer else { return }
        renderer.pull(from: stream.decoder)
        if let layout = stream.layout, layout != lastLayout {
            lastLayout = layout
            geometry.updateRemoteSize(layout.codedSize)
            geometry.setSourceRect(layout.contentRect)
            switch fitMode {
            case .fit: geometry.scaleMode = .fit
            case .fill: geometry.scaleMode = .fill
            case .actual: geometry.scaleMode = .pixelPerfect(screenScale: layout.scale)
            }
        }
        for update in stream.drainSurfaceUpdates() {
            switch update {
            case .upsert(let id, let offset, let image):
                if children[id] == nil, children.count >= WindowStream.maxSurfaces { continue }
                let surface = children[id]?.surface ?? BGRAImageSurface(device: renderer.device)
                if surface.update(image) { children[id] = (surface, offset) }
            case .remove(let id):
                children[id] = nil
            }
        }
        if let layout = stream.layout {
            renderer.children = children.values.map { child in
                ChildSurface(
                    surface: child.surface,
                    offset: CGPoint(
                        x: layout.contentRect.minX + child.offset.x * layout.scale,
                        y: layout.contentRect.minY + child.offset.y * layout.scale
                    )
                )
            }
        }
        let cursor = stream.currentCursor()
        if cursor.version != lastCursorVersion {
            lastCursorVersion = cursor.version
            renderer.setCursor(cursor.image ?? .defaultArrow)
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let renderer, let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let buffer = renderer.makeCommandBuffer() else { return }
        renderer.encode(
            into: buffer, pass: pass, geometry: geometry, deviceScale: Double(view.contentScaleFactor), pointer: pointerPixel
        )
        buffer.present(drawable)
        buffer.commit()
    }

    /// The local cursor sits where the last input put the pointer, in pixels of the coded frame.
    private var pointerPixel: (x: Int, y: Int)? {
        guard touchMapper.hasPointer, let layout = lastLayout else { return nil }
        let point = touchMapper.pointer
        return (
            Int(layout.contentRect.minX + Double(point.x) * layout.scale), Int(layout.contentRect.minY + Double(point.y) * layout.scale)
        )
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        geometry.updateViewSize(bounds.size)
        requestFrame()
        let scale = traitCollection.displayScale > 0 ? traitCollection.displayScale : contentScaleFactor
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        if size != lastReportedPixelSize, size.width > 0, size.height > 0 {
            lastReportedPixelSize = size
            onViewPixelSize?(size)
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { startDisplayLink() } else { stopDisplayLink() }
        if window != nil { _ = becomeFirstResponder() }
    }

    /// Zoom and pan back to the base view.
    func resetZoom() {
        geometry.reset()
        requestFrame()
    }

    // MARK: Input space

    /// The window coordinate space for what is on screen now; `nil` until the first picture says how big the window is.
    private var space: WindowCoordinateSpace? {
        guard let layout = lastLayout, bounds.width > 0, bounds.height > 0 else { return nil }
        let surfaces = children.values.map { child in
            CGRect(
                x: child.offset.x, y: child.offset.y,
                width: Double(child.surface.size.width) / layout.scale, height: Double(child.surface.size.height) / layout.scale
            )
        }
        return WindowCoordinateSpace(
            windowSize: layout.windowSize, backingScale: layout.scale, viewSize: bounds.size, fitMode: fitMode,
            zoom: geometry.zoom, pan: geometry.pan, surfaces: surfaces
        )
    }

    private func dispatch(_ event: TouchEvent) {
        guard let space else { return }
        guard acceptsRemoteInput else {
            switch event {
            case .pan(_, let translation, _), .twoFingerPan(_, let translation, _):
                geometry.pan(by: translation)
                requestFrame()
            default: break
            }
            return
        }
        // Mouse and hover go through the router: a drag that starts inside stays captured outside, one that starts outside is not ours.
        switch event {
        case .hover(let location):
            guard router.route(viewPoint: location, buttons: [], in: space) != nil else { return }
        case .mouseButton(let location, let button, let phase):
            let bit: PointerButtons = button == .primary ? .left : .right
            if phase == .ended { mouseButtons.remove(bit) } else { mouseButtons.insert(bit) }
            guard router.route(viewPoint: location, buttons: mouseButtons, in: space) != nil else { return }
        default: break
        }
        let output = touchMapper.handle(event, in: space, isZoomed: space.isZoomed)
        if !output.intents.isEmpty {
            onIntents?(output.intents)
            requestFrame()
        }
        if let pan = output.viewportPan {
            geometry.pan(by: pan)
            requestFrame()
        }
    }

    // MARK: Gestures

    private var pinchRecognizer: UIPinchGestureRecognizer!
    private var twoFingerPanRecognizer: UIPanGestureRecognizer!
    private var hoverRecognizer: UIHoverGestureRecognizer!
    private var wheelRecognizer: UIPanGestureRecognizer!

    private func installGestures() {
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        let twoFingerTap = UITapGestureRecognizer(target: self, action: #selector(handleTwoFingerTap(_:)))
        twoFingerTap.numberOfTouchesRequired = 2
        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        longPress.minimumPressDuration = 0.35
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.maximumNumberOfTouches = 1
        pan.require(toFail: longPress)
        twoFingerPanRecognizer = UIPanGestureRecognizer(target: self, action: #selector(handleTwoFingerPan(_:)))
        twoFingerPanRecognizer.minimumNumberOfTouches = 2
        twoFingerPanRecognizer.maximumNumberOfTouches = 2
        pinchRecognizer = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        let fingers = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        for recognizer in [tap, twoFingerTap, longPress, pan, twoFingerPanRecognizer!, pinchRecognizer!] as [UIGestureRecognizer] {
            recognizer.allowedTouchTypes = fingers
            recognizer.delegate = self
            addGestureRecognizer(recognizer)
        }

        let pencilRecognizer = UILongPressGestureRecognizer(target: self, action: #selector(handlePencil(_:)))
        pencilRecognizer.minimumPressDuration = 0
        pencilRecognizer.allowableMovement = .greatestFiniteMagnitude
        pencilRecognizer.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.pencil.rawValue)]

        let indirect = [NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
        let primaryMouse = UILongPressGestureRecognizer(target: self, action: #selector(handleMouseButton(_:)))
        primaryMouse.minimumPressDuration = 0
        primaryMouse.allowableMovement = .greatestFiniteMagnitude
        primaryMouse.allowedTouchTypes = indirect
        let secondaryMouse = UITapGestureRecognizer(target: self, action: #selector(handleSecondaryClick(_:)))
        secondaryMouse.buttonMaskRequired = .secondary
        secondaryMouse.allowedTouchTypes = indirect
        hoverRecognizer = UIHoverGestureRecognizer(target: self, action: #selector(handleHover(_:)))
        wheelRecognizer = UIPanGestureRecognizer(target: self, action: #selector(handleWheel(_:)))
        wheelRecognizer.allowedScrollTypesMask = .all
        wheelRecognizer.allowedTouchTypes = []
        for recognizer in [pencilRecognizer, primaryMouse, secondaryMouse, hoverRecognizer!, wheelRecognizer!] as [UIGestureRecognizer] {
            recognizer.delegate = self
            addGestureRecognizer(recognizer)
        }
    }

    private func phase(of recognizer: UIGestureRecognizer) -> GesturePhase {
        switch recognizer.state {
        case .began: .began
        case .changed: .changed
        default: .ended
        }
    }

    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) { dispatch(.tap(recognizer.location(in: self), count: 1)) }
    @objc private func handleTwoFingerTap(_ recognizer: UITapGestureRecognizer) { dispatch(.twoFingerTap(recognizer.location(in: self))) }
    @objc private func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
        dispatch(.longPress(recognizer.location(in: self), phase(of: recognizer)))
    }

    @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
        let translation = recognizer.translation(in: self)
        recognizer.setTranslation(.zero, in: self)
        dispatch(.pan(location: recognizer.location(in: self), translation: translation, phase(of: recognizer)))
    }

    @objc private func handleTwoFingerPan(_ recognizer: UIPanGestureRecognizer) {
        let translation = recognizer.translation(in: self)
        recognizer.setTranslation(.zero, in: self)
        let location = recognizer.location(in: self)
        let phase = phase(of: recognizer)
        if phase == .began { stopMomentum() }
        dispatch(.twoFingerPan(location: location, translation: translation, phase))
        if recognizer.state == .ended, momentum.start(velocity: recognizer.velocity(in: self), at: location) {
            momentumIsWheel = false
            lastMomentumTick = nil
            requestFrame()
        }
    }

    @objc private func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
        switch recognizer.state {
        case .began: pinchStartZoom = geometry.zoom
        case .changed:
            geometry.setZoom(pinchStartZoom * Double(recognizer.scale), around: recognizer.location(in: self))
            requestFrame()
        default: break
        }
    }

    @objc private func handlePencil(_ recognizer: UILongPressGestureRecognizer) {
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
        if recognizer.state == .ended, momentum.start(velocity: recognizer.velocity(in: self), at: location) {
            momentumIsWheel = true
            lastMomentumTick = nil
            requestFrame()
        }
    }

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

    private func stepMomentum(_ link: CADisplayLink) {
        let seconds = lastMomentumTick.map { link.targetTimestamp - $0 } ?? link.duration
        lastMomentumTick = link.targetTimestamp
        dispatch(momentumEvent(momentum.advance(by: seconds), .changed))
        if !momentum.isActive { dispatch(momentumEvent(.zero, .ended)) }
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === hoverRecognizer || other === hoverRecognizer { return true }
        let twoFinger: [UIGestureRecognizer?] = [pinchRecognizer, twoFingerPanRecognizer]
        return twoFinger.contains { $0 === gestureRecognizer } && twoFinger.contains { $0 === other }
    }

    // MARK: Focus

    override var canBecomeFirstResponder: Bool { true }
    override var inputView: UIView? { isSoftwareKeyboardVisible ? nil : emptyInputView }
    override var editingInteractionConfiguration: UIEditingInteractionConfiguration { .none }

    override func resignFirstResponder() -> Bool {
        commitComposition()
        let resigned = super.resignFirstResponder()
        if resigned {
            let intents = keyboard.releaseAll()
            updateKeyRepeat()
            if !intents.isEmpty { onIntents?(intents) }
        }
        return resigned
    }

    @objc private func sceneDidActivate(_ notification: Notification) {
        guard isOwnScene(notification) else { return }
        if window != nil, !isFirstResponder { _ = becomeFirstResponder() }
    }

    /// Per scene: another window of the app going inactive must not release input here.
    @objc private func sceneWillDeactivate(_ notification: Notification) {
        guard isOwnScene(notification) else { return }
        releaseAllInput()
    }

    private func isOwnScene(_ notification: Notification) -> Bool {
        guard let scene = notification.object as? UIScene, let own = window?.windowScene else { return false }
        return scene === own
    }

    /// Releases keys and buttons and ends scrolling, so the Mac is never left with a stuck key or mouse button.
    func releaseAllInput() {
        momentum.stop()
        commitComposition()
        mouseButtons = []
        router.cancel()
        let intents = keyboard.releaseAll() + touchMapper.releaseAll()
        updateKeyRepeat()
        if !intents.isEmpty { onIntents?(intents) }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        if window != nil, !isFirstResponder { _ = becomeFirstResponder() }
        stopMomentum()
        super.touchesBegan(touches, with: event)
    }

    // MARK: Hardware keyboard

    override var keyCommands: [UIKeyCommand]? {
        let escape = UIKeyCommand(action: #selector(escapePressed), input: UIKeyCommand.inputEscape, modifierFlags: [])
        escape.wantsPriorityOverSystemBehavior = true
        return [escape]
    }

    @objc private func escapePressed() { onIntents?(InputIntent.tap(0xFF1B, macKeyCode: 53)) }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if !handle(presses, isDown: true) { super.pressesBegan(presses, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if !handle(presses, isDown: false) { super.pressesEnded(presses, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if !handle(presses, isDown: false) { super.pressesCancelled(presses, with: event) }
    }

    /// With a composing input method (Vietnamese, Chinese...) a plain character goes to the text system, which composes it; shortcuts and
    /// special keys still go straight to the Mac as keys.
    private var inputMethodComposes: Bool {
        guard let language = textInputMode?.primaryLanguage else { return false }
        return !language.hasPrefix("en") && language != "emoji" && language != "dictation"
    }

    private func handle(_ presses: Set<UIPress>, isDown: Bool) -> Bool {
        guard acceptsRemoteInput else { return false }
        var intents: [InputIntent] = []
        var handled = false
        for press in presses {
            guard let key = press.key else { continue }
            var modifiers: KeyModifiers = []
            if key.modifierFlags.contains(.shift) { modifiers.insert(.shift) }
            if key.modifierFlags.contains(.control) { modifiers.insert(.control) }
            if key.modifierFlags.contains(.alternate) { modifiers.insert(.option) }
            if key.modifierFlags.contains(.command) { modifiers.insert(.command) }
            let isModifierKey = (0xE0...0xE7).contains(key.keyCode.rawValue)
            let isPlainCharacter = !isModifierKey && modifiers.isDisjoint(with: [.control, .command])
                && key.characters.unicodeScalars.count == 1 && (key.characters.unicodeScalars.first.map { $0.value >= 0x20 && $0.value < 0xF700 } ?? false)
            if inputMethodComposes, isPlainCharacter { continue }
            let result = keyboard.handle(KeyPress(
                hidUsage: key.keyCode.rawValue, characters: key.characters,
                charactersIgnoringModifiers: key.charactersIgnoringModifiers, modifiers: modifiers, isDown: isDown
            ))
            if !result.isEmpty { handled = true }
            intents += result
        }
        if !intents.isEmpty { onIntents?(intents) }
        updateKeyRepeat()
        return handled
    }

    private func updateKeyRepeat() {
        guard keyboard.repeating != scheduledRepeat else { return }
        repeatTask?.cancel()
        repeatTask = nil
        scheduledRepeat = keyboard.repeating
        guard let key = scheduledRepeat else { return }
        repeatTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: KeyRepeat.initialDelay)
            let stopAt = ContinuousClock.now + KeyRepeat.maximumDuration
            while !Task.isCancelled, ContinuousClock.now < stopAt, self?.repeatOnce(key) == true {
                try? await Task.sleep(for: KeyRepeat.interval)
            }
        }
    }

    private func repeatOnce(_ key: RepeatingKey) -> Bool {
        guard keyboard.repeating == key else { return false }
        onIntents?([.key(key.keysym, isDown: true)])
        return true
    }

    // MARK: UIKeyInput and UITextInput (input methods)

    var hasText: Bool { true }

    /// Final text from the keyboard. Marked text being replaced is committed with it; Return and Tab are keys, the rest is text.
    func insertText(_ text: String) {
        guard !text.isEmpty else { return }
        willChangeText()
        composing = ""
        composingSelection = NSRange(location: 0, length: 0)
        didChangeText()
        onIntents?(Self.intents(forTyped: text))
    }

    func deleteBackward() {
        if !composing.isEmpty {
            willChangeText()
            composing.removeLast()
            composingSelection = NSRange(location: (composing as NSString).length, length: 0)
            didChangeText()
        } else {
            onIntents?(InputIntent.tap(0xFF08, macKeyCode: 51))
        }
    }

    /// Splits typed text so that line breaks and tabs become keys and everything else one `.text` intent per run.
    static func intents(forTyped text: String) -> [InputIntent] {
        var result: [InputIntent] = []
        var run = ""
        func flush() {
            if !run.isEmpty { result.append(.text(run)) }
            run = ""
        }
        for character in text {
            switch character {
            case "\n", "\r", "\r\n":
                flush()
                result += InputIntent.tap(0xFF0D, macKeyCode: 36)
            case "\t":
                flush()
                result += InputIntent.tap(0xFF09, macKeyCode: 48)
            default:
                run.append(character)
            }
        }
        flush()
        return result
    }

    private func commitComposition() {
        guard !composing.isEmpty else { return }
        let text = composing
        willChangeText()
        composing = ""
        composingSelection = NSRange(location: 0, length: 0)
        didChangeText()
        onIntents?(Self.intents(forTyped: text))
    }

    private func willChangeText() {
        inputDelegate?.selectionWillChange(self)
        inputDelegate?.textWillChange(self)
    }

    private func didChangeText() {
        inputDelegate?.textDidChange(self)
        inputDelegate?.selectionDidChange(self)
    }

    weak var inputDelegate: UITextInputDelegate?
    var markedTextStyle: [NSAttributedString.Key: Any]?
    private(set) lazy var tokenizer: UITextInputTokenizer = UITextInputStringTokenizer(textInput: self)

    private var length: Int { (composing as NSString).length }

    var selectedTextRange: UITextRange? {
        get {
            let end = min(composingSelection.location + composingSelection.length, length)
            return TextRange(start: min(composingSelection.location, end), end: end)
        }
        set {
            guard let range = newValue as? TextRange else { return }
            composingSelection = NSRange(location: min(range.startOffset, length), length: max(0, min(range.endOffset, length) - range.startOffset))
        }
    }

    var markedTextRange: UITextRange? { composing.isEmpty ? nil : TextRange(start: 0, end: length) }
    var beginningOfDocument: UITextPosition { TextPosition(0) }
    var endOfDocument: UITextPosition { TextPosition(length) }

    func setMarkedText(_ markedText: String?, selectedRange: NSRange) {
        willChangeText()
        composing = markedText ?? ""
        let limit = length
        composingSelection = NSRange(location: min(max(selectedRange.location, 0), limit), length: 0)
        didChangeText()
    }

    func unmarkText() { commitComposition() }

    func text(in range: UITextRange) -> String? {
        guard let range = range as? TextRange else { return nil }
        let start = min(max(range.startOffset, 0), length), end = min(max(range.endOffset, start), length)
        return (composing as NSString).substring(with: NSRange(location: start, length: end - start))
    }

    func replace(_ range: UITextRange, withText text: String) {
        guard let range = range as? TextRange, !composing.isEmpty else { insertText(text); return }
        let start = min(max(range.startOffset, 0), length), end = min(max(range.endOffset, start), length)
        willChangeText()
        composing = (composing as NSString).replacingCharacters(in: NSRange(location: start, length: end - start), with: text)
        didChangeText()
    }

    func textRange(from fromPosition: UITextPosition, to toPosition: UITextPosition) -> UITextRange? {
        guard let from = fromPosition as? TextPosition, let to = toPosition as? TextPosition else { return nil }
        return TextRange(start: min(from.offset, to.offset), end: max(from.offset, to.offset))
    }

    func position(from position: UITextPosition, offset: Int) -> UITextPosition? {
        guard let position = position as? TextPosition else { return nil }
        let (sum, overflow) = position.offset.addingReportingOverflow(offset)
        guard !overflow else { return nil }
        return TextPosition(min(max(sum, 0), length))
    }

    func position(from position: UITextPosition, in direction: UITextLayoutDirection, offset: Int) -> UITextPosition? {
        self.position(from: position, offset: offset)
    }

    func compare(_ position: UITextPosition, to other: UITextPosition) -> ComparisonResult {
        guard let a = position as? TextPosition, let b = other as? TextPosition else { return .orderedSame }
        return a.offset == b.offset ? .orderedSame : (a.offset < b.offset ? .orderedAscending : .orderedDescending)
    }

    func offset(from: UITextPosition, to toPosition: UITextPosition) -> Int {
        guard let a = from as? TextPosition, let b = toPosition as? TextPosition else { return 0 }
        return b.offset - a.offset
    }

    func position(within range: UITextRange, farthestIn direction: UITextLayoutDirection) -> UITextPosition? {
        guard let range = range as? TextRange else { return nil }
        switch direction {
        case .left, .up: return TextPosition(range.startOffset)
        default: return TextPosition(range.endOffset)
        }
    }

    func characterRange(byExtending position: UITextPosition, in direction: UITextLayoutDirection) -> UITextRange? {
        guard let position = position as? TextPosition else { return nil }
        return TextRange(start: position.offset, end: position.offset)
    }

    func baseWritingDirection(for position: UITextPosition, in direction: UITextStorageDirection) -> NSWritingDirection { .natural }
    func setBaseWritingDirection(_ writingDirection: NSWritingDirection, for range: UITextRange) {}

    /// Where the input method puts its candidate list: at the bottom of the window.
    func firstRect(for range: UITextRange) -> CGRect { CGRect(x: bounds.midX, y: max(bounds.maxY - 48, 0), width: 2, height: 24) }
    func caretRect(for position: UITextPosition) -> CGRect { firstRect(for: TextRange(start: 0, end: 0)) }
    func selectionRects(for range: UITextRange) -> [UITextSelectionRect] { [] }
    func closestPosition(to point: CGPoint) -> UITextPosition? { TextPosition(length) }
    func closestPosition(to point: CGPoint, within range: UITextRange) -> UITextPosition? { (range as? TextRange)?.end }
    func characterRange(at point: CGPoint) -> UITextRange? { TextRange(start: 0, end: 0) }

    // Text goes to the Mac as typed: no correction, capitalisation or smart punctuation on this side.
    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var spellCheckingType: UITextSpellCheckingType = .no
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no
    var smartInsertDeleteType: UITextSmartInsertDeleteType = .no
    var inlinePredictionType: UITextInlinePredictionType = .no
}

// MARK: - Text positions

private final class TextPosition: UITextPosition {
    let offset: Int
    init(_ offset: Int) { self.offset = offset }
}

private final class TextRange: UITextRange {
    let startOffset: Int
    let endOffset: Int
    init(start: Int, end: Int) {
        startOffset = start
        endOffset = end
    }
    override var start: UITextPosition { TextPosition(startOffset) }
    override var end: UITextPosition { TextPosition(endOffset) }
    override var isEmpty: Bool { startOffset >= endOffset }
}

// MARK: - Display link target and pointer

private final class LinkProxy: NSObject {
    private weak var view: AppWindowView?
    init(_ view: AppWindowView) { self.view = view }

    @MainActor @objc func tick(_ link: CADisplayLink) {
        guard let view else {
            link.invalidate()
            return
        }
        view.tick(link)
    }
}

extension AppWindowView: UIPointerInteractionDelegate {
    /// The Mac cursor is drawn locally, so the iPad's own pointer is hidden over the window.
    func pointerInteraction(_ interaction: UIPointerInteraction, styleFor region: UIPointerRegion) -> UIPointerStyle? {
        acceptsRemoteInput ? .hidden() : nil
    }
}
