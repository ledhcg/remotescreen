import InputKit
import LinkProtocol
import MetalKit
import RemoteDisplay
import RFBKit
import UIKit
import UniformTypeIdentifiers
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
            observeTransfers()
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
    private var lastCursorStyleVersion = -1
    private var touchMapper = TouchMapper()
    private var router = InputRouter()
    private var keyboard = KeyboardState()
    private var pencil = PencilGesture()
    /// What the pencil last reported while touching, and the hardest it pressed during the stroke (a tap ends with the tip lifting).
    private var pencilSample: PencilSample?
    private var pencilPeakPressure = 0.0
    /// Input waits here while the Mac is being given the iPad's clipboard before a paste (see `holdInputForPaste`).
    private var heldIntents: [[InputIntent]] = []
    private var holdTask: Task<Void, Never>?
    private var transfersHUD: FileTransfersHUD?
    private var transfersObserver: NSObjectProtocol?
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
        // Black like the scene behind it and like the capture's fill: the Mac window's rounded corners arrive filled with black
        // (`ScreenCaptureKitSystem`), so any other letterbox colour shows four dark wedges at the window's corners.
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
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
        addInteraction(UIDropInteraction(delegate: self))
    }

    // MARK: Services (clipboard, files)

    /// The clipboard and file transfers of the connection this window shows.
    private var services: AppWindowServices? { stream?.services }

    private func observeTransfers() {
        if let transfersObserver { NotificationCenter.default.removeObserver(transfersObserver) }
        transfersObserver = nil
        guard let files = services?.files else { transfersHUD?.update(items: [], cancel: { _ in }); return }
        transfersObserver = NotificationCenter.default.addObserver(
            forName: AppFileTransfers.didChange, object: files, queue: .main
        ) { [weak self, weak files] _ in
            MainActor.assumeIsolated { self?.refreshTransfersHUD(files) }
        }
        refreshTransfersHUD(files)
    }

    private func refreshTransfersHUD(_ files: AppFileTransfers?) {
        guard let files else { return }
        if transfersHUD == nil, !files.items.isEmpty {
            let hud = FileTransfersHUD()
            hud.translatesAutoresizingMaskIntoConstraints = false
            addSubview(hud)
            NSLayoutConstraint.activate([
                hud.centerXAnchor.constraint(equalTo: centerXAnchor),
                hud.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -16),
                hud.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -32),
                hud.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
            ])
            transfersHUD = hud
        }
        transfersHUD?.update(items: files.items) { [weak files] id in files?.cancel(id) }
        if !files.items.isEmpty, files.items.allSatisfy(\.isFinished) {
            Task { @MainActor [weak files] in
                try? await Task.sleep(for: .seconds(5))
                if let files, files.items.allSatisfy(\.isFinished) { files.dismissFinished() }
            }
        }
    }

    // MARK: Input gate

    /// Sends intents to the Mac in order. While a paste is waiting for the clipboard to reach the Mac they queue up behind it.
    private func emit(_ intents: [InputIntent]) {
        guard !intents.isEmpty else { return }
        if holdTask != nil { heldIntents.append(intents) } else { onIntents?(intents) }
    }

    /// ⌘V needs the iPad's clipboard on the Mac first: the offer, the Mac's request and the data take a round trip.
    private func holdInputForPaste() {
        holdTask?.cancel()
        holdTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            self?.flushHeldInput()
        }
    }

    /// Sends what was held back, now, in order.
    private func flushHeldInput() {
        holdTask?.cancel()
        holdTask = nil
        let batches = heldIntents
        heldIntents = []
        for batch in batches { onIntents?(batch) }
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
        if cursor.version != lastCursorVersion || CursorStylePreference.version != lastCursorStyleVersion {
            lastCursorVersion = cursor.version
            lastCursorStyleVersion = CursorStylePreference.version
            let macCursor = cursor.image ?? .defaultArrow
            renderer.setCursor(CursorStylePreference.current.replacement(for: macCursor) ?? macCursor)
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let renderer, let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let buffer = renderer.makeCommandBuffer() else { return }
        renderer.encode(
            into: buffer, pass: pass, geometry: geometry, deviceScale: Double(view.contentScaleFactor), pointer: pointerPixel,
            cornerRadius: pictureCornerRadius
        )
        buffer.present(drawable)
        buffer.commit()
    }

    /// Corner radius of a Mac window in Mac points.
    private static let macCornerRadius = 14.0

    /// The window picture's corner radius in view points: Mac points to coded-frame pixels to view points. 0 until there is a layout.
    private var pictureCornerRadius: Double {
        guard let layout = lastLayout else { return 0 }
        return Self.macCornerRadius * layout.scale * geometry.scale
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
            emit(output.intents)
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
        pencilRecognizer.cancelsTouchesInView = false  // the view reads force and angles from the touches themselves

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
        for action in actions {
            if let sample = strokeSample(for: action) { dispatch(.pencilStroke(action, sample)) } else { dispatch(.pencil(action)) }
        }
        if recognizer.state == .ended || recognizer.state == .cancelled || recognizer.state == .failed { pencilPeakPressure = 0 }
    }

    /// The pencil's pressure and tilt for an action, when the Mac takes them and the system reported them.
    private func strokeSample(for action: PencilAction) -> PencilSample? {
        guard services?.supportsTablet == true, var sample = pencilSample else { return nil }
        switch action {
        case .click: sample.pressure = max(sample.pressure, pencilPeakPressure)  // the tip is already lifting when a tap is recognised
        case .rightClick: return nil
        default: break
        }
        return sample
    }

    private func notePencil(_ touches: Set<UITouch>) {
        guard let touch = touches.first(where: { $0.type == .pencil }) else { return }
        let sample = PencilSample(
            force: Double(touch.force), maximumForce: Double(touch.maximumPossibleForce),
            altitude: Double(touch.altitudeAngle), azimuth: Double(touch.azimuthAngle(in: self))
        )
        pencilSample = sample
        pencilPeakPressure = max(pencilPeakPressure, sample.pressure)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        notePencil(touches)
        super.touchesMoved(touches, with: event)
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
        let location = recognizer.location(in: self)
        // A hovering Apple Pencil reports its height; a mouse or trackpad reports none. The Mac gets a stylus in proximity, not a mouse.
        if services?.supportsTablet == true, recognizer.zOffset > 0 {
            let sample = PencilSample(
                force: 0, maximumForce: 1, altitude: Double(recognizer.altitudeAngle), azimuth: Double(recognizer.azimuthAngle(in: self))
            )
            dispatch(.pencilHover(location, sample))
            return
        }
        dispatch(.hover(location))
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
        flushHeldInput()
        commitComposition()
        let resigned = super.resignFirstResponder()
        if resigned {
            let intents = keyboard.releaseAll()
            updateKeyRepeat()
            if !intents.isEmpty { emit(intents) }
        }
        return resigned
    }

    @objc private func sceneDidActivate(_ notification: Notification) {
        guard isOwnScene(notification) else { return }
        services?.sceneBecameActive()
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
        flushHeldInput()
        momentum.stop()
        commitComposition()
        mouseButtons = []
        router.cancel()
        let intents = keyboard.releaseAll() + touchMapper.releaseAll()
        updateKeyRepeat()
        if !intents.isEmpty { emit(intents) }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        if window != nil, !isFirstResponder { _ = becomeFirstResponder() }
        stopMomentum()
        notePencil(touches)
        super.touchesBegan(touches, with: event)
    }

    // MARK: Hardware keyboard

    override var keyCommands: [UIKeyCommand]? {
        let escape = UIKeyCommand(action: #selector(escapePressed), input: UIKeyCommand.inputEscape, modifierFlags: [])
        escape.wantsPriorityOverSystemBehavior = true
        return [escape]
    }

    @objc private func escapePressed() { emit(InputIntent.tap(0xFF1B, macKeyCode: 53)) }

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
            if isDown, modifiers.contains(.command), !isModifierKey { noteClipboardShortcut(key.charactersIgnoringModifiers) }
            let result = keyboard.handle(KeyPress(
                hidUsage: key.keyCode.rawValue, characters: key.characters,
                charactersIgnoringModifiers: key.charactersIgnoringModifiers, modifiers: modifiers, isDown: isDown
            ))
            if !result.isEmpty { handled = true }
            intents += result
        }
        if !intents.isEmpty { emit(intents) }
        updateKeyRepeat()
        return handled
    }

    /// ⌘C / ⌘X: the Mac's clipboard is about to change. ⌘V: give the Mac the iPad's clipboard first, and hold the keys until it has had time.
    private func noteClipboardShortcut(_ characters: String) {
        switch characters.lowercased() {
        case "c", "x": services?.copyShortcutPressed()
        case "v": if services?.pasteShortcutPressed() == true { holdInputForPaste() }
        default: break
        }
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
        emit([.key(key.keysym, isDown: true)])
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
        emit(Self.intents(forTyped: text))
    }

    func deleteBackward() {
        if !composing.isEmpty {
            willChangeText()
            composing.removeLast()
            composingSelection = NSRange(location: (composing as NSString).length, length: 0)
            didChangeText()
        } else {
            emit(InputIntent.tap(0xFF08, macKeyCode: 51))
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
        emit(Self.intents(forTyped: text))
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

// MARK: - Dropping files

extension AppWindowView: UIDropInteractionDelegate {
    func dropInteraction(_ interaction: UIDropInteraction, canHandle session: UIDropSession) -> Bool {
        guard stream?.services?.supportsFiles == true, acceptsRemoteInput else { return false }
        return session.hasItemsConforming(toTypeIdentifiers: [UTType.data.identifier, UTType.directory.identifier])
    }

    func dropInteraction(_ interaction: UIDropInteraction, sessionDidUpdate session: UIDropSession) -> UIDropProposal {
        UIDropProposal(operation: .copy)
    }

    /// Each dropped item is copied to a private temporary file inside the provider's callback (its own file disappears when the callback
    /// returns), then queued. The Mac opens the file with this window's app, and only if it is a plain document type.
    func dropInteraction(_ interaction: UIDropInteraction, performDrop session: UIDropSession) {
        guard let services = stream?.services, let window = stream?.window else { return }
        let target = services.bundleID(window)
        for item in session.items.prefix(FileDropPolicy.maxQueued + 4) {
            let provider = item.itemProvider
            let suggested = provider.suggestedName ?? String(localized: "File")
            let typeIdentifier = provider.registeredTypeIdentifiers.first { identifier in
                UTType(identifier)?.conforms(to: .data) == true || UTType(identifier)?.conforms(to: .directory) == true
            } ?? UTType.data.identifier
            provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { url, _ in
                guard let url else {
                    Task { @MainActor in services.files.refuse(name: suggested, reason: .unreadable) }
                    return
                }
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
                if values?.isDirectory == true {
                    Task { @MainActor in services.files.refuse(name: suggested, reason: .folder) }
                    return
                }
                if let size = values?.fileSize, !FileDropPolicy.isAcceptable(size: UInt64(size)) {
                    let reason: AppFileTransfers.Item.Refusal = size == 0 ? .empty : .tooLarge
                    Task { @MainActor in services.files.refuse(name: suggested, reason: reason) }
                    return
                }
                let folder = FileManager.default.temporaryDirectory
                    .appending(path: AppFileTransfers.temporaryFolderName, directoryHint: .isDirectory)
                    .appending(path: UUID().uuidString, directoryHint: .isDirectory)
                let copy = folder.appending(path: "file", directoryHint: .notDirectory)
                do {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    try FileManager.default.copyItem(at: url, to: copy)
                } catch {
                    try? FileManager.default.removeItem(at: folder)
                    Task { @MainActor in services.files.refuse(name: suggested, reason: .unreadable) }
                    return
                }
                Task { @MainActor in services.files.enqueue(copiedFile: copy, suggestedName: suggested, targetBundleID: target) }
            }
        }
    }
}

/// The list of files being sent, over the bottom of the window: name, progress, a cancel button; finished ones show how they ended.
@MainActor
final class FileTransfersHUD: UIView {
    private let stack = UIStackView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        // The same card as the SwiftUI ones (`Theme.chromeCard`): dark, near opaque, hairline edge, continuous 18-point corners.
        overrideUserInterfaceStyle = .dark
        let card = UIView()
        card.translatesAutoresizingMaskIntoConstraints = false
        card.backgroundColor = UIColor(Theme.chromeBar)
        card.layer.cornerRadius = Theme.Radius.card
        card.layer.cornerCurve = .continuous
        card.layer.borderWidth = 1
        card.layer.borderColor = UIColor(Theme.hairline).cgColor
        card.clipsToBounds = true
        addSubview(card)
        stack.axis = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: leadingAnchor), card.trailingAnchor.constraint(equalTo: trailingAnchor),
            card.topAnchor.constraint(equalTo: topAnchor), card.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -12),
        ])
        accessibilityIdentifier = "file-transfers"
        accessibilityLabel = String(localized: "File transfers")
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(items: [AppFileTransfers.Item], cancel: @escaping (UInt32) -> Void) {
        for view in stack.arrangedSubviews { stack.removeArrangedSubview(view); view.removeFromSuperview() }
        isHidden = items.isEmpty
        for item in items {
            let label = UILabel()
            label.font = .preferredFont(forTextStyle: .subheadline)
            label.adjustsFontForContentSizeCategory = true
            label.numberOfLines = 2
            label.text = Self.text(for: item)
            label.textColor = Self.isFailure(item) ? UIColor(Theme.destructive) : UIColor(Theme.onChrome)
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

            let row = UIStackView(arrangedSubviews: [label])
            row.axis = .horizontal
            row.spacing = 10
            row.alignment = .center
            if !item.isFinished {
                let progress = UIProgressView(progressViewStyle: .default)
                progress.progress = Float(item.fraction)
                progress.widthAnchor.constraint(equalToConstant: 90).isActive = true
                var configuration = UIButton.Configuration.plain()
                configuration.image = UIImage(systemName: "xmark.circle.fill")
                configuration.baseForegroundColor = UIColor(Theme.onChromeSecondary) // monochrome like every icon of the chrome
                let button = UIButton(configuration: configuration, primaryAction: UIAction { _ in cancel(item.id) })
                button.accessibilityLabel = String(localized: "Cancel")
                button.accessibilityIdentifier = "cancel-transfer"
                row.addArrangedSubview(progress)
                row.addArrangedSubview(button)
            }
            row.isAccessibilityElement = false
            stack.addArrangedSubview(row)
        }
    }

    private static func isFailure(_ item: AppFileTransfers.Item) -> Bool {
        switch item.state {
        case .failed, .refused: true
        default: false
        }
    }

    static func text(for item: AppFileTransfers.Item) -> String {
        let name = item.name
        switch item.state {
        case .queued: return String(localized: "Waiting to send “\(name)”")
        case .sending: return String(localized: "Sending “\(name)”")
        case .sent: return String(localized: "Sent “\(name)”")
        case .cancelled: return String(localized: "Cancelled “\(name)”")
        case .failed: return String(localized: "Couldn't send “\(name)”")
        case .refused(let reason):
            switch reason {
            case .tooLarge: return String(localized: "“\(name)” is too large to send.")
            case .empty: return String(localized: "“\(name)” is empty.")
            case .folder: return String(localized: "“\(name)” is a folder. Folders can't be sent.")
            case .unreadable: return String(localized: "“\(name)” couldn't be read.")
            case .queueFull: return String(localized: "Too many files are waiting. “\(name)” was not sent.")
            case .notConnected: return String(localized: "Not connected to the Mac. “\(name)” was not sent.")
            }
        }
    }
}
