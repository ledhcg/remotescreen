#if canImport(UIKit)
import InputKit
import MetalKit
import RFBKit
import UIKit

@MainActor
public protocol RemoteScreenViewDelegate: AnyObject {
    func remoteScreenView(_ view: RemoteScreenView, didChangeGeometry geometry: ViewportGeometry)
}

/// View hiển thị màn hình Mac bằng Metal và thu nhận thao tác của người dùng: chạm, bàn phím cứng, bàn phím ảo.
///
/// - Hiển thị: chụm để phóng, kéo để xem phần ngoài màn hình khi đã phóng.
/// - Nhập liệu: cử chỉ chạm được `InputKit.TouchMapper` đổi thành sự kiện chuột, phím được `KeyboardState` đổi thành keysym.
///   Mọi thông điệp ra ngoài qua `onInput`, nơi người dùng view nối vào `RFBSession.post`.
@MainActor
public final class RemoteScreenView: MTKView, MTKViewDelegate, UIGestureRecognizerDelegate, UIKeyInput {
    public weak var geometryDelegate: RemoteScreenViewDelegate?

    /// Nhận mọi thông điệp chuột/phím cần gửi tới Mac, theo đúng thứ tự.
    public var onInput: (([ClientMessage]) -> Void)?

    public private(set) var geometry = ViewportGeometry(remoteSize: .zero, viewSize: .zero)
    private var renderer: FramebufferRenderer?
    private var touchMapper = TouchMapper()
    private var keyboard = KeyboardState()
    /// Lặp phím khi giữ: iPadOS không gửi lại `pressesBegan` cho phím đang giữ, nên view tự lặp (xem `KeyboardState.repeating`).
    private var repeatTask: Task<Void, Never>?
    private var scheduledRepeat: RepeatingKey?

    /// Cách hiểu cử chỉ. Đổi `mode` để chuyển giữa chạm trực tiếp và bàn di chuột.
    public var touchPolicy: TouchPolicy {
        get { touchMapper.policy }
        set { touchMapper.policy = newValue }
    }

    /// Chế độ đặt màn hình Mac lên thiết bị. Điểm ảnh gốc cần biết số pixel mỗi point của **màn hình đang hiển thị view**, nên
    /// được tính lại khi view vào cửa sổ (có thể là màn hình ngoài với tỉ lệ khác).
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

    /// Bàn phím ảo hiện hay ẩn. Bàn phím cứng luôn dùng được; ẩn bàn phím ảo chỉ bỏ phần hiển thị trên màn hình.
    public var isSoftwareKeyboardVisible = false {
        didSet {
            guard oldValue != isSoftwareKeyboardVisible else { return }
            if !isFirstResponder { _ = becomeFirstResponder() }
            reloadInputViews()
        }
    }

    // MARK: - Khởi tạo

    private var pinchRecognizer: UIPinchGestureRecognizer!
    private var twoFingerPanRecognizer: UIPanGestureRecognizer!
    private let emptyInputView = UIView(frame: .zero) // đặt làm `inputView` để ẩn bàn phím ảo mà vẫn nhận phím cứng

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
        // Vẽ theo nhịp màn hình bằng `CADisplayLink` của riêng view (xem `requestFrame`), chỉ khi có việc: nhiều cập nhật tới
        // trong một nhịp được gộp thành một lần vẽ, khoảng cách giữa các khung đều hơn, và đứng yên thì không vẽ gì (tiết kiệm pin).
        enableSetNeedsDisplay = false
        isPaused = true
        delegate = self
        isMultipleTouchEnabled = true
        backgroundColor = .black
        // Quay lại app (từ nền, hộp thoại hệ thống, menu...) thì lấy lại tiêu điểm bàn phím, nếu không phím cứng không tới nữa.
        NotificationCenter.default.addObserver(
            self, selector: #selector(reclaimKeyboardFocus), name: UIApplication.didBecomeActiveNotification, object: nil
        )

        // Một phần tử trợ năng duy nhất, cho phép tương tác trực tiếp (VoiceOver không chặn cử chỉ chạm).
        isAccessibilityElement = true
        accessibilityIdentifier = "remoteScreen"
        accessibilityLabel = "Màn hình từ xa"
        accessibilityTraits = .allowsDirectInteraction

        if let device {
            renderer = try? FramebufferRenderer(device: device, colorPixelFormat: colorPixelFormat)
            renderer?.setCursor(.defaultArrow) // dùng tạm tới khi server gửi hình con trỏ thật
        }

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))

        let twoFingerTap = UITapGestureRecognizer(target: self, action: #selector(handleTwoFingerTap(_:)))
        twoFingerTap.numberOfTouchesRequired = 2

        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        longPress.minimumPressDuration = 0.35

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.minimumNumberOfTouches = 1
        pan.maximumNumberOfTouches = 1
        pan.require(toFail: longPress) // đè giữ trước thì là kéo-thả; nhúc nhích ngay thì là kéo thường

        twoFingerPanRecognizer = UIPanGestureRecognizer(target: self, action: #selector(handleTwoFingerPan(_:)))
        twoFingerPanRecognizer.minimumNumberOfTouches = 2
        twoFingerPanRecognizer.maximumNumberOfTouches = 2

        pinchRecognizer = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        rotationRecognizer = UIRotationGestureRecognizer(target: self, action: #selector(handleRotation(_:)))

        // Các cử chỉ ngón tay chỉ nhận ngón tay: bút và chuột có bộ nhận diện riêng bên dưới, với cách hiểu khác (tuyệt đối, tức thì).
        let fingers = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        for recognizer in [tap, twoFingerTap, longPress, pan, twoFingerPanRecognizer!, pinchRecognizer!, rotationRecognizer!] {
            recognizer.allowedTouchTypes = fingers
            recognizer.delegate = self
            addGestureRecognizer(recognizer)
        }

        // Apple Pencil: nhận nét bút thô ngay từ lúc đầu bút chạm (giữ 0 giây), `PencilGesture` phân loại chạm, kéo, giữ.
        let pencilRecognizer = UILongPressGestureRecognizer(target: self, action: #selector(handlePencil(_:)))
        pencilRecognizer.minimumPressDuration = 0
        pencilRecognizer.allowableMovement = .greatestFiniteMagnitude
        pencilRecognizer.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.pencil.rawValue)]

        // Chuột và trackpad gắn vào iPad (cần `UIApplicationSupportsIndirectInputEvents`): bấm là nhấn ngay, như chuột thật.
        let indirect = [NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
        let primaryMouse = UILongPressGestureRecognizer(target: self, action: #selector(handleMouseButton(_:)))
        primaryMouse.minimumPressDuration = 0
        primaryMouse.allowableMovement = .greatestFiniteMagnitude
        primaryMouse.allowedTouchTypes = indirect
        // Nút phải: chỉ bộ nhận diện chạm mới chọn được nút (`buttonMaskRequired`), nên nút phải là một cú nhấp, không kéo.
        let secondaryMouse = UITapGestureRecognizer(target: self, action: #selector(handleSecondaryClick(_:)))
        secondaryMouse.buttonMaskRequired = .secondary
        secondaryMouse.allowedTouchTypes = indirect

        // Di chuột không bấm (và bút lơ lửng trên iPad có hỗ trợ): di con trỏ Mac theo.
        hoverRecognizer = UIHoverGestureRecognizer(target: self, action: #selector(handleHover(_:)))
        // Bánh xe chuột, hai ngón trên trackpad: chỉ nhận sự kiện cuộn, không nhận cú chạm nào.
        wheelRecognizer = UIPanGestureRecognizer(target: self, action: #selector(handleWheel(_:)))
        wheelRecognizer.allowedScrollTypesMask = .all
        wheelRecognizer.allowedTouchTypes = []

        for recognizer in [pencilRecognizer, primaryMouse, secondaryMouse, hoverRecognizer!, wheelRecognizer!] {
            recognizer.delegate = self
            addGestureRecognizer(recognizer)
        }
        addInteraction(UIPointerInteraction(delegate: self))
        addInteraction(UIPencilInteraction(delegate: self))

        // Vào nền hay mất focus thì nhả hết phím và nút chuột, để Mac không bị kẹt (ví dụ Command không bao giờ được nhả).
        NotificationCenter.default.addObserver(
            self, selector: #selector(releaseAllInput), name: UIApplication.willResignActiveNotification, object: nil
        )
    }

    // MARK: - Dữ liệu từ phiên

    /// Đưa một khung hình mới lên GPU rồi yêu cầu vẽ.
    public func display(_ framebuffer: Framebuffer, dirty: [PixelRect]? = nil) {
        updatesSincePresent += 1
        renderer?.upload(framebuffer, dirty: dirty)
        let size = CGSize(width: framebuffer.width, height: framebuffer.height)
        if geometry.remoteSize != size {
            geometry.updateRemoteSize(size)
            geometryChanged() // báo cả delegate lẫn giá trị trợ năng (cỡ đang hiển thị đổi theo cỡ Mac)
        }
        requestFrame()
    }

    /// Đặt hình con trỏ do server gửi. Server Apple tách con trỏ khỏi ảnh màn hình nên ta phải tự vẽ nó.
    /// Hình rỗng nghĩa là server ẩn con trỏ.
    public func setCursor(_ cursor: CursorImage) {
        renderer?.setCursor(cursor)
        requestFrame()
    }

    // MARK: - Nhịp vẽ

    private var displayLink: CADisplayLink?
    private var needsFrame = false
    private var idleTicks = 0
    private var updatesSincePresent = 0

    /// Một khung có nội dung mới vừa được vẽ: thời điểm (giây, đồng hồ `CACurrentMediaTime`) và số cập nhật đã gộp vào nó.
    /// Dùng cho số liệu độ mượt.
    public var onContentPresented: ((CFTimeInterval, Int) -> Void)?

    /// Xin vẽ ở nhịp màn hình kế tiếp. Gọi nhiều lần trong một nhịp chỉ vẽ một lần.
    public func requestFrame() {
        needsFrame = true
        idleTicks = 0
        displayLink?.isPaused = false
    }

    private func startDisplayLink() {
        guard displayLink == nil else { return }
        // Proxy giữ view yếu: `CADisplayLink` giữ chặt target của nó, giữ trực tiếp view sẽ không bao giờ giải phóng.
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
            if !needsFrame { return } // quán tính cuộn Mac không cần vẽ lại khung; dịch khung nhìn thì đã xin vẽ
        }
        guard needsFrame else {
            // Hai nhịp liền không có việc: tạm dừng, lần `requestFrame()` sau đánh thức lại.
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

    /// `false` khi server vẽ con trỏ vào khung hình (app không xin hình con trỏ riêng): vẽ thêm mũi tên tại chỗ sẽ thành hai con trỏ.
    public var drawsLocalCursor = true {
        didSet { requestFrame() }
    }

    /// Không nhận cử chỉ sửa văn bản của iPadOS (ba ngón để hoàn tác, chép, dán): view này nhận phím nhưng không phải ô văn bản,
    /// và các cử chỉ đó sẽ nuốt cú chạm ba ngón dành cho màn hình Mac.
    public override var editingInteractionConfiguration: UIEditingInteractionConfiguration { .none }

    /// Có vẽ con trỏ của Mac không. Con trỏ nằm ở vị trí ta gửi lần cuối: RFB không báo khi chuột thật của Mac di chuyển.
    public var showsRemoteCursor = true {
        didSet { requestFrame() }
    }

    // MARK: - Bố cục và vẽ

    /// Cỡ khung nhìn theo **pixel thiết bị** mỗi khi nó đổi (xoay máy, Split View, Stage Manager). Dùng cho chế độ "theo độ
    /// phân giải thiết bị", nơi server Apple thu nhỏ hình đúng bằng cỡ này.
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
        // Cho VoiceOver (và UI test) biết màn hình Mac đang hiện ở cỡ nào.
        let shown = geometry.contentRect
        accessibilityValue = "Màn hình Mac \(Int(geometry.remoteSize.width))×\(Int(geometry.remoteSize.height)), "
            + "hiển thị \(Int(shown.width.rounded()))×\(Int(shown.height.rounded())) điểm"
        geometryDelegate?.remoteScreenView(self, didChangeGeometry: geometry)
    }

    /// Khung nhìn đang nhỏ hơn nội dung ở ít nhất một chiều, nên kéo được để xem phần bị che.
    private var isZoomed: Bool {
        let content = geometry.contentRect
        return content.width > bounds.width + 0.5 || content.height > bounds.height + 0.5
    }

    // MARK: - Cử chỉ chạm

    /// `false` ở chế độ chỉ xem: cử chỉ không điều khiển Mac và con trỏ vẽ không di chuyển (trước đây nó vẫn chạy theo ngón tay,
    /// tới chỗ con trỏ thật của Mac không hề tới). Kéo vẫn dịch khung nhìn khi đang phóng, chụm vẫn phóng.
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
        if !output.messages.isEmpty {
            onInput?(output.messages)
            requestFrame() // con trỏ có thể đã di chuyển
            // Phím bổ trợ dính một lần (chạm ⌘ trên sidebar hay thanh phím phụ) chỉ áp cho MỘT thao tác: trước đây nó chỉ nhả sau
            // một phím, nên sau ⌘-click nó vẫn giữ và phím gõ kế tiếp thành tổ hợp ⌘ ngoài ý muốn. Phím đang khóa thì giữ.
            if PointerActions.completesAButtonAction(output.messages, previousButtons: &lastSentButtons) {
                let release = modifierKeys.actionCompleted()
                if !release.isEmpty { onInput?(release) }
            }
        }
        if let pan = output.viewportPan {
            geometry.pan(by: pan)
            geometryChanged()
        }
    }

    /// Nút chuột (trái, giữa, phải) đã gửi lần cuối, để biết khi nào một cú nhấp hay một lần kéo vừa kết thúc.
    private var lastSentButtons: UInt8 = 0

    private func phase(of recognizer: UIGestureRecognizer) -> GesturePhase {
        switch recognizer.state {
        case .began: .began
        case .changed: .changed
        default: .ended
        }
    }

    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        guard !limitsFingers else { return }
        // Hai lần chạm liên tiếp là hai lần nhấp; macOS tự nhận ra nhấp đúp theo thời gian và vị trí.
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
        recognizer.setTranslation(.zero, in: self) // gửi quãng tăng thêm, không cộng dồn
        let location = recognizer.location(in: self)
        if limitsFingers {
            // Đã dùng bút và chọn "ngón tay chỉ cuộn": một ngón kéo là cuộn (hay dịch khung nhìn khi đang phóng), như Sidecar.
            dispatch(.twoFingerPan(location: location, translation: translation, phase(of: recognizer)))
            return
        }
        dispatch(.pan(location: location, translation: translation, phase(of: recognizer)))
    }

    // MARK: Apple Pencil, chuột và trackpad của iPad

    private var pencil = PencilGesture()
    private var hasSeenPencil = false
    private var hoverRecognizer: UIHoverGestureRecognizer!
    private var wheelRecognizer: UIPanGestureRecognizer!

    /// "Ngón tay chỉ cuộn khi dùng bút" (như Sidecar): sau nét bút đầu tiên, ngón tay chỉ cuộn và phóng, chạm không nhấp.
    public var fingersOnlyScrollWithPencil = false

    /// Chạm hai lần lên Apple Pencil (thế hệ 2, Pro). App chọn việc cần làm.
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
        // Trackpad: nhấc hai ngón khi đang vuốt thì cuộn tiếp, như trên Mac. Bánh xe chuột (rời rạc) gần như không có vận tốc.
        if recognizer.state == .ended, momentum.start(velocity: recognizer.velocity(in: self), at: location) {
            momentumIsWheel = true
            lastMomentumTick = nil
            requestFrame()
        }
    }

    /// Nhấp phải tại vị trí con trỏ hiện tại (ví dụ khi chạm hai lần lên bút).
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
            // Đang chụm/xoay trên Mac: trackpad thật không vừa cuộn vừa chụm. Đóng lần cuộn đang mở (nếu có) rồi bỏ qua.
            if scrollOpen { dispatch(.twoFingerPan(location: location, translation: .zero, .ended)) }
            scrollOpen = false
            return
        }
        scrollOpen = phase != .ended
        dispatch(.twoFingerPan(location: location, translation: translation, phase))
        // Nhấc tay khi đang vuốt: cuộn tiếp và chậm dần như trackpad (chỉ khi cử chỉ kết thúc bình thường, không phải bị hủy).
        if recognizer.state == .ended, momentum.start(velocity: recognizer.velocity(in: self), at: location) {
            momentumIsWheel = false
            lastMomentumTick = nil
            requestFrame()
        }
    }

    // MARK: Quán tính

    private var momentum = MomentumScroller()
    private var lastMomentumTick: CFTimeInterval?
    /// Quán tính đến từ trackpad của iPad (luôn cuộn Mac) chứ không phải hai ngón trên màn hình.
    private var momentumIsWheel = false

    /// Bước quán tính đi qua đúng đường của cử chỉ đã sinh ra nó.
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

    /// Một bước quán tính mỗi nhịp màn hình, đi qua đúng đường của cử chỉ hai ngón (nấc cuộn, hoặc dịch khung nhìn khi đang phóng).
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
    /// Lần cuộn hai ngón đang mở (đã gửi began, chưa gửi ended).
    private var scrollOpen = false

    /// "Chụm/xoay: gửi lên Mac" (chỉ server Apple, message 23): chụm thành phóng trên Mac, xoay thành xoay. Tắt thì chụm phóng
    /// khung nhìn trên iPad như trước, xoay không làm gì.
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
        // UIKit: radian, dương theo chiều kim đồng hồ. NSEvent: độ, dương ngược chiều kim đồng hồ.
        let degrees = -(radians - lastRotation) * 180 / .pi
        dispatch(.rotate(location: recognizer.location(in: self), degrees: degrees, phase))
        lastRotation = radians
    }

    @objc private func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
        if pinchSendsToMac, acceptsRemoteInput {
            // Gửi lên Mac: mỗi bước là thay đổi tỉ lệ so với bước trước, như `NSEvent.magnification`.
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

    /// Vùng (toạ độ cửa sổ) mà view không nhận cử chỉ, vì có điều khiển nổi nằm đè lên (thanh công cụ).
    ///
    /// Cử chỉ của view này nằm sâu hơn trong cây view nên thắng nút SwiftUI ở trên và HỦY nó: chạm vào nút không làm
    /// gì, còn cú chạm thì thành một cú nhấp xuống màn hình Mac ngay dưới nút. Với Mac thật, bấm "Ngắt kết nối" sẽ
    /// nhấp nhầm vào thứ nằm dưới thanh công cụ.
    public var excludedRegions: [CGRect] = []

    public func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        // Cử chỉ nhiều ngón không bị chặn: một ngón vô tình đặt lên thanh công cụ không nên làm hỏng cả cử chỉ.
        // (Bài test XCUITest `twoFingerTap()` đặt hai ngón cách nhau gần cả chiều cao màn hình, một ngón rơi vào thanh công cụ.)
        let isMultiTouch = gestureRecognizer === pinchRecognizer || gestureRecognizer === twoFingerPanRecognizer
            || gestureRecognizer === rotationRecognizer
            || ((gestureRecognizer as? UITapGestureRecognizer)?.numberOfTouchesRequired ?? 1) > 1
        if isMultiTouch { return true }
        let point = touch.location(in: nil)
        return !excludedRegions.contains { $0.contains(point) }
    }

    public func gestureRecognizer(_ gesture: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        // Chụm và kéo hai ngón diễn ra cùng lúc (vừa phóng vừa dịch). Di chuột không chặn gì (và không bị gì chặn).
        // Các cử chỉ khác loại trừ lẫn nhau.
        if gesture === hoverRecognizer || other === hoverRecognizer { return true }
        // Chụm, xoay và kéo hai ngón cùng lúc được (khi gửi lên Mac, cuộn tạm dừng trong lúc chụm/xoay: xem `handleTwoFingerPan`).
        let twoFinger: [UIGestureRecognizer?] = [pinchRecognizer, rotationRecognizer, twoFingerPanRecognizer]
        return twoFinger.contains { $0 === gesture } && twoFinger.contains { $0 === other }
    }

    // MARK: - Bàn phím

    public override var canBecomeFirstResponder: Bool { true }

    public override var inputView: UIView? { isSoftwareKeyboardVisible ? nil : emptyInputView }

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { startDisplayLink() } else { stopDisplayLink() }
        if window != nil, displayMode == .native { applyDisplayMode() } // tỉ lệ pixel của màn hình vừa vào
        if window != nil { _ = becomeFirstResponder() } // cần là first responder thì mới nhận phím cứng
    }

    /// iPadOS giữ lại Escape cho chính nó (đóng cửa sổ nổi, hủy...) nên nó không bao giờ tới `pressesBegan`: đo trên iPad thật
    /// và simulator, Escape gõ vào mà server không thấy gì. Lệnh phím có quyền ưu tiên hơn hệ thống thì nhận được nó.
    public override var keyCommands: [UIKeyCommand]? {
        let escape = UIKeyCommand(action: #selector(escapePressed), input: UIKeyCommand.inputEscape, modifierFlags: [])
        escape.wantsPriorityOverSystemBehavior = true
        // ⌘F là "Tìm" của hệ thống iPadOS nên không tới `pressesBegan` (đo trên simulator iPad); Mac từ xa cần nó cho Safari, trình soạn thảo...
        let find = UIKeyCommand(action: #selector(commandChordPressed(_:)), input: "f", modifierFlags: .command)
        find.wantsPriorityOverSystemBehavior = true
        return [escape, find]
    }

    @objc private func escapePressed() {
        onInput?(VirtualKey.escape.tap + modifierKeys.actionCompleted())
    }

    @objc private func commandChordPressed(_ sender: UIKeyCommand) {
        let commandDown = keyboard.isHolding(keysym: KeysymMapper.commandLeft) || keyboard.isHolding(keysym: KeysymMapper.commandRight)
            || modifierKeys.active.contains(.command)
        guard let input = sender.input, let character = input.first,
              let chord = KeysymMapper.commandChord(character, commandAlreadyDown: commandDown) else { return }
        onInput?(chord + modifierKeys.actionCompleted())
    }

    /// Mất tiêu điểm bàn phím (menu, cửa sổ khác lấy nó): lần nhả của phím đang giữ sẽ tới chỗ khác, nên nhả ngay bây giờ,
    /// kể cả dừng lặp phím. Không thì Mac thấy phím kẹt, hoặc Backspace lặp mãi.
    public override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned {
            let messages = keyboard.releaseAll()
            updateKeyRepeat()
            if !messages.isEmpty { onInput?(messages) }
        }
        return resigned
    }

    @objc private func reclaimKeyboardFocus() {
        if window != nil, !isFirstResponder { _ = becomeFirstResponder() }
    }

    /// Chạm vào màn hình cũng đòi lại tiêu điểm bàn phím: một điều khiển SwiftUI vừa dùng có thể đã lấy nó.
    public override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        reclaimKeyboardFocus()
        stopMomentum() // chạm lại thì dừng ngay, như cuộn trên trackpad
        super.touchesBegan(touches, with: event)
    }

    /// Bàn phím cứng: mỗi phím nhấn/nhả được đổi sang keysym.
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
        var messages: [ClientMessage] = []
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
        // Phím bổ trợ dính trên sidebar hay thanh phím phụ nhả sau khi phím thường được thả, để thứ tự là Cmd↓ c↓ c↑ Cmd↑.
        if releasedAPlainKey { messages += modifierKeys.actionCompleted() }
        if !messages.isEmpty { onInput?(messages) }
        updateKeyRepeat()
        return handled
    }

    /// Bắt đầu, đổi hoặc dừng việc lặp phím theo `keyboard.repeating`. Sau độ trễ ban đầu, gửi lại lần nhấn đều đặn cho tới khi
    /// phím nhả (hoặc phím khác được nhấn). Chỉ gửi "nhấn", không "nhả" xen giữa, đúng như lần lặp của bàn phím thật.
    private func updateKeyRepeat() {
        guard keyboard.repeating != scheduledRepeat else { return }
        repeatTask?.cancel()
        repeatTask = nil
        scheduledRepeat = keyboard.repeating
        guard let key = scheduledRepeat else { return }
        repeatTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: KeyRepeat.initialDelay)
            let stopAt = ContinuousClock.now + KeyRepeat.maximumDuration
            // Không giữ `self` qua lúc ngủ: view có thể đã bị hủy.
            while !Task.isCancelled, ContinuousClock.now < stopAt, self?.repeatOnce(key) == true {
                try? await Task.sleep(for: KeyRepeat.interval)
            }
        }
    }

    /// Gửi một lần lặp nếu `key` vẫn là phím đang giữ. Trả về `false` khi nên dừng.
    private func repeatOnce(_ key: RepeatingKey) -> Bool {
        guard keyboard.repeating == key else { return false }
        onInput?([.keyEvent(isDown: true, keysym: key.keysym)])
        return true
    }

    /// Nhả mọi phím và nút chuột đang giữ. Gọi khi vào nền, mất focus hoặc ngắt kết nối.
    @objc public func releaseAllInput() {
        momentum.stop()
        let messages = keyboard.releaseAll() + modifierKeys.releaseAll() + touchMapper.releaseAll()
        updateKeyRepeat()
        if !messages.isEmpty { onInput?(messages) }
    }

    // MARK: Phím bổ trợ (sidebar, thanh phím phụ)

    /// Phím bổ trợ đang nhấn trên Mac do sidebar hay thanh phím phụ (giữ, dính một lần, khóa). Đổi thì `onModifierStatesChange`
    /// được gọi.
    public private(set) var modifierKeys = ModifierKeys() {
        didSet {
            if oldValue != modifierKeys { onModifierStatesChange?(modifierKeys.states) }
        }
    }

    public var onModifierStatesChange: (([StickyModifier: ModifierState]) -> Void)?

    /// Ngón đặt lên một phím bổ trợ của sidebar: nhấn ngay trên Mac (để ⌘-click bằng tay kia).
    public func modifierTouchDown(_ modifier: StickyModifier) {
        let messages = modifierKeys.touchDown(modifier, at: CACurrentMediaTime())
        if !messages.isEmpty { onInput?(messages) }
    }

    /// Ngón nhấc khỏi phím bổ trợ: nhả, hoặc thành dính một lần nếu đó là một cái chạm ngắn.
    public func modifierTouchUp(_ modifier: StickyModifier) {
        let messages = modifierKeys.touchUp(modifier, at: CACurrentMediaTime())
        if !messages.isEmpty { onInput?(messages) }
    }

    /// Chạm một phím bổ trợ trên thanh phím phụ: dính một lần; chạm hai lần nhanh thì khóa; chạm khi đang dính hay khóa thì bỏ.
    public func toggleModifier(_ modifier: StickyModifier) {
        let messages = modifierKeys.tap(modifier, at: CACurrentMediaTime())
        if !messages.isEmpty { onInput?(messages) }
    }

    /// Nhả mọi phím bổ trợ của sidebar và thanh phím phụ (ví dụ khi ẩn sidebar: phím đang khóa không được kẹt lại mà không thấy).
    public func releaseModifiers() {
        let messages = modifierKeys.releaseAll()
        if !messages.isEmpty { onInput?(messages) }
    }

    /// Bấm một phím trên thanh phím phụ hay sidebar. Phím bổ trợ dính một lần được nhả ngay sau đó.
    public func press(_ key: VirtualKey) {
        onInput?(key.tap + modifierKeys.actionCompleted())
    }

    /// ⌘ + một chữ (nút Hoàn tác của sidebar là ⌘Z). Không nhấn ⌘ lần nữa nếu nó đang được giữ hay khóa: lần nhả thứ hai sẽ làm
    /// Mac thấy ⌘ đã nhả trong khi sidebar vẫn báo đang giữ. Phím khác đang dính vẫn áp dụng (⇧ dính + Hoàn tác = ⌘⇧Z).
    public func pressCommandChord(_ character: Character) {
        let commandDown = modifierKeys.active.contains(.command)
        guard let chord = KeysymMapper.commandChord(character, commandAlreadyDown: commandDown) else { return }
        onInput?(chord + modifierKeys.actionCompleted())
    }

    // MARK: UIKeyInput (bàn phím ảo)

    public var hasText: Bool { true }

    public func insertText(_ text: String) {
        let typed = KeyboardState.typing(text)
        guard !typed.isEmpty else { return }
        onInput?(typed + modifierKeys.actionCompleted()) // Ctrl/Cmd đang dính chỉ áp dụng cho ký tự này
    }

    public func deleteBackward() {
        onInput?([.keyEvent(isDown: true, keysym: 0xFF08), .keyEvent(isDown: false, keysym: 0xFF08)] + modifierKeys.actionCompleted()) // Backspace
    }

    // Tắt tự sửa, tự viết hoa: văn bản đi thẳng tới Mac, nơi mới là nơi xử lý.
    public var autocorrectionType: UITextAutocorrectionType = .no
    public var autocapitalizationType: UITextAutocapitalizationType = .none
    public var spellCheckingType: UITextSpellCheckingType = .no
    public var smartQuotesType: UITextSmartQuotesType = .no
    public var smartDashesType: UITextSmartDashesType = .no
}
/// Đích của `CADisplayLink`, giữ view yếu (display link giữ chặt đích của nó).
private final class DisplayLinkProxy: NSObject {
    private weak var view: RemoteScreenView?

    init(_ view: RemoteScreenView) {
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

// MARK: - Con trỏ của iPad, chạm hai lần lên bút

extension RemoteScreenView: UIPointerInteractionDelegate, UIPencilInteractionDelegate {
    /// Ẩn con trỏ tròn của iPad trên màn hình Mac: con trỏ của Mac (vẽ tại chỗ hay do server vẽ) đã đi theo chuột rồi, hai con
    /// trỏ chồng nhau chỉ rối. Chỉ xem hoặc đã tắt con trỏ Mac thì giữ con trỏ iPad để còn biết chuột đang ở đâu.
    public func pointerInteraction(_ interaction: UIPointerInteraction, styleFor region: UIPointerRegion) -> UIPointerStyle? {
        acceptsRemoteInput && showsRemoteCursor ? .hidden() : nil
    }

    public func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveTap tap: UIPencilInteraction.Tap) {
        guard acceptsRemoteInput else { return }
        onPencilDoubleTap?()
    }
}
#endif
