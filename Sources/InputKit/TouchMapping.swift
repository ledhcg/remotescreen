import CoreGraphics
import Foundation
import RFBKit

/// Cách đổi toạ độ giữa khung nhìn và màn hình từ xa. `ViewportGeometry` (module RemoteDisplay) tuân theo giao thức này,
/// nhờ đó `InputKit` không phải biết gì về Metal hay UIKit.
public protocol RemoteCoordinateSpace {
    var remoteSize: CGSize { get }
    /// Số point trên mỗi pixel Mac ở mức phóng hiện tại.
    var pointsPerRemotePixel: Double { get }
    /// `clamped == false` trả `nil` khi điểm rơi ngoài màn hình (chạm vào viền đen).
    func remotePixel(forView point: CGPoint, clamped: Bool) -> (x: Int, y: Int)?
}

public enum TouchMode: Sendable, Equatable {
    /// Chạm vào đâu, thao tác diễn ra ngay chỗ đó trên màn hình Mac (như thao tác trên màn hình cảm ứng).
    case directTouch
    /// Ngón tay điều khiển con trỏ tương đối như bàn di chuột: kéo để di chuyển, chạm để nhấp tại con trỏ.
    case trackpad
}

public enum DragBehavior: Sendable, Equatable {
    /// Chỉ di chuyển con trỏ (di chuột, không nhấn).
    case moveCursor
    /// Nhấn giữ nút trái và kéo (chọn văn bản, kéo thả).
    case dragWithLeftButton
    /// Kéo khung nhìn đi, không gửi gì cho Mac. Hữu ích khi đang phóng to.
    case panViewport
}

public enum TwoFingerBehavior: Sendable, Equatable {
    /// Cuộn bằng bánh xe chuột.
    case scroll
    case panViewport
}

/// Các lựa chọn về cách hiểu cử chỉ. Gom ở một chỗ để dễ chỉnh theo thói quen.
public struct TouchPolicy: Sendable, Equatable {
    public var mode: TouchMode = .directTouch
    /// Cuộn kiểu iOS: kéo ngón lên thì nội dung đi lên (tức cuộn xuống).
    public var naturalScrolling = true
    /// Số point ngón phải kéo để ra một nấc cuộn.
    public var scrollTickDistance = 24.0
    /// Hệ số nhân tốc độ di chuyển ở chế độ trackpad.
    public var trackpadSensitivity = 1.6
    /// Server Apple và người dùng bật "cuộn mượt": cuộn bằng `kCGEventScrollWheel` có pha và quán tính (message 23) thay vì
    /// nấc bánh xe. Server khác không hiểu message này, nên mặc định tắt.
    public var appleSmoothScroll = false
    /// Pixel framebuffer mỗi point của Mac, để nội dung trên Mac đi đúng bằng quãng ngón tay. 1 đã kiểm trên Mac thật
    /// (2560x1440 ở 1x: `NSEvent.scrollingDeltaY` đúng bằng quãng gửi đi). Mac Retina có thể là 2 nếu framebuffer tính theo
    /// pixel thật; chưa có máy Retina để đo, và RFB không báo tỉ lệ này.
    public var remotePixelsPerMacPoint = 1.0

    public init(mode: TouchMode = .directTouch) {
        self.mode = mode
    }

    /// **Một ngón kéo thì làm gì?** Đây là quyết định UX quan trọng nhất của app.
    ///
    /// Mặc định: chế độ trackpad luôn di chuyển con trỏ; chế độ chạm trực tiếp thì kéo khung nhìn khi đang phóng to
    /// (để xem được phần ngoài màn hình) và di chuyển con trỏ khi chưa phóng. Kéo-thả thật dùng nhấn giữ rồi kéo.
    public func oneFingerDrag(isZoomed: Bool) -> DragBehavior {
        switch mode {
        case .trackpad: .moveCursor
        case .directTouch: isZoomed ? .panViewport : .moveCursor
        }
    }

    /// **Hai ngón kéo thì làm gì?** Mặc định cuộn, trừ khi đang phóng to thì kéo khung nhìn.
    public func twoFingerPan(isZoomed: Bool) -> TwoFingerBehavior {
        isZoomed ? .panViewport : .scroll
    }
}

public enum GesturePhase: Sendable, Equatable {
    case began, changed, ended
}

/// Cử chỉ đã nhận dạng, tách khỏi UIKit.
public enum TouchEvent: Sendable, Equatable {
    case tap(CGPoint, count: Int)
    case twoFingerTap(CGPoint)
    case longPress(CGPoint, GesturePhase)
    /// Một ngón kéo. `location` là vị trí hiện tại, `translation` là quãng vừa di chuyển kể từ sự kiện trước.
    case pan(location: CGPoint, translation: CGPoint, GesturePhase)
    case twoFingerPan(location: CGPoint, translation: CGPoint, GesturePhase)
    /// Một nét Apple Pencil đã phân loại (`PencilGesture`). Luôn tuyệt đối, bất kể chế độ chạm.
    case pencil(PencilAction)
    /// Di con trỏ không bấm nút: chuột hay trackpad của iPad, bút lơ lửng. Luôn tuyệt đối.
    case hover(CGPoint)
    /// Nút chuột (hay cú bấm trackpad) của iPad: nhấn (`began`), kéo (`changed`), nhả (`ended`) tại vị trí tuyệt đối.
    case mouseButton(CGPoint, MouseButton, GesturePhase)
    /// Cuộn bằng bánh xe chuột hay hai ngón trên trackpad của iPad: luôn cuộn Mac (kể cả khi đang phóng), tại vị trí con trỏ.
    case scroll(location: CGPoint, translation: CGPoint, GesturePhase)
    /// Nhấp phải tại vị trí con trỏ hiện tại (chạm hai lần lên Apple Pencil).
    case secondaryClickAtPointer
    /// Chụm gửi lên Mac (message 23 loại 3): `scaleDelta` là thay đổi tỉ lệ so với lần trước (0,05 = phóng thêm 5%).
    case magnify(location: CGPoint, scaleDelta: Double, GesturePhase)
    /// Xoay gửi lên Mac (message 23 loại 5): độ, dương là ngược chiều kim đồng hồ.
    case rotate(location: CGPoint, degrees: Double, GesturePhase)
}

/// Nút của chuột hay trackpad gắn vào iPad.
public enum MouseButton: Sendable, Equatable {
    case primary, secondary
}

/// Việc cần làm sau một cử chỉ.
public struct TouchOutput: Equatable, Sendable {
    /// Thông điệp gửi tới Mac, theo thứ tự.
    public var messages: [ClientMessage] = []
    /// Nếu có, khung nhìn cần kéo đi từng ấy point.
    public var viewportPan: CGPoint?
}

/// Biến cử chỉ chạm thành sự kiện chuột RFB.
public struct TouchMapper: Sendable {
    public var policy: TouchPolicy

    /// Vị trí con trỏ trên màn hình Mac, pixel Mac.
    public private(set) var pointer: (x: Int, y: Int) {
        didSet { hasPointer = true }
    }
    /// `true` từ khi app đặt con trỏ lần đầu. Trước đó ta không biết con trỏ thật của Mac đang ở đâu
    /// (RFB không báo vị trí), nên không nên vẽ một con trỏ giả ở (0, 0).
    public private(set) var hasPointer = false
    private var buttons: UInt8 = 0
    private var lastLocation: CGPoint?
    private var scrollAccumulator = CGPoint.zero
    private var isDragging = false
    private enum AppleScrollState { case idle, scrolling, momentum }
    private var appleScrollState = AppleScrollState.idle
    private var appleScrollRemainder = CGPoint.zero

    static let leftButton: UInt8 = 1 << 0
    static let rightButton: UInt8 = 1 << 2
    static let wheelUp: UInt8 = 1 << 3
    static let wheelDown: UInt8 = 1 << 4
    static let wheelLeft: UInt8 = 1 << 5
    static let wheelRight: UInt8 = 1 << 6

    /// - Parameter initialPointer: vị trí con trỏ nếu đã biết. Bỏ trống nghĩa là chưa biết (`hasPointer == false`).
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
            for _ in 0..<max(1, count) { output.messages += click(Self.leftButton, at: target) }

        case .twoFingerTap(let point):
            guard let target = target(at: point, in: space) else { return output }
            output.messages += click(Self.rightButton, at: target)

        case .longPress(let point, let phase):
            output.messages += dragStep(to: point, phase: phase, in: space)

        case .pan(let location, let translation, let phase):
            switch policy.oneFingerDrag(isZoomed: isZoomed) {
            case .moveCursor:
                if let target = movedTarget(location: location, translation: translation, phase: phase, in: space) {
                    output.messages.append(pointerMessage(target))
                }
            case .dragWithLeftButton:
                output.messages += dragStep(to: location, phase: phase, in: space)
            case .panViewport:
                if phase == .changed { output.viewportPan = translation }
            }

        case .twoFingerPan(let location, let translation, let phase):
            switch policy.twoFingerPan(isZoomed: isZoomed) {
            case .scroll:
                output.messages += scroll(location: location, translation: translation, phase: phase, in: space)
            case .panViewport:
                if phase == .changed { output.viewportPan = translation }
            }

        case .pencil(let action):
            output.messages += pencil(action, in: space)

        case .hover(let location):
            if let target = absoluteTarget(location, in: space) { output.messages.append(pointerMessage(target)) }

        case .mouseButton(let location, let button, let phase):
            let bit = button == .primary ? Self.leftButton : Self.rightButton
            guard let target = absoluteTarget(location, in: space) else { return output }
            switch phase {
            case .began:
                output.messages.append(pointerMessage(target))
                buttons |= bit
            case .changed:
                break
            case .ended:
                buttons &= ~bit
            }
            output.messages.append(pointerMessage(target))

        case .scroll(let location, let translation, let phase):
            output.messages += scroll(location: location, translation: translation, phase: phase, in: space, atLocation: true)

        case .secondaryClickAtPointer:
            guard hasPointer else { return output }
            output.messages += click(Self.rightButton, at: pointer)

        case .magnify(let location, let delta, let phase):
            output.messages += gesture(at: location, value: delta, phase: phase, in: space) { .magnify($0, phase: $1, x: $2, y: $3) }

        case .rotate(let location, let degrees, let phase):
            output.messages += gesture(at: location, value: degrees, phase: phase, in: space) { .rotate($0, phase: $1, x: $2, y: $3) }
        }
        return output
    }

    /// Nhả mọi nút đang giữ (khi cử chỉ bị hủy, vào nền, ngắt kết nối) để Mac không bị kẹt nút chuột.
    public mutating func releaseAll() -> [ClientMessage] {
        defer { buttons = 0; isDragging = false; lastLocation = nil; scrollAccumulator = .zero }
        guard buttons != 0 else { return [] }
        return [.pointerEvent(buttons: 0, x: clampedX(pointer.x), y: clampedY(pointer.y))]
    }

    // MARK: - Chọn vị trí

    /// Chạm trực tiếp: điểm chạm. Trackpad: vị trí con trỏ hiện tại. `nil` nếu chạm vào viền đen ở chế độ trực tiếp.
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

    /// Vị trí mới khi một ngón kéo ở chế độ "di chuyển con trỏ".
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
            // Chưa biết con trỏ thật đang ở đâu thì xuất phát từ giữa màn hình, đừng xuất phát từ góc (0, 0).
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

    /// Vị trí tuyệt đối (bút, chuột): điểm dưới đầu bút hay con trỏ, kẹp vào màn hình Mac.
    private mutating func absoluteTarget(_ location: CGPoint, in space: some RemoteCoordinateSpace) -> (x: Int, y: Int)? {
        guard let pixel = space.remotePixel(forView: location, clamped: true) else { return nil }
        pointer = pixel
        return pixel
    }

    /// Chụm/xoay trên Mac: lúc bắt đầu đưa con trỏ tới giữa hai ngón (ứng dụng Mac phóng quanh con trỏ), rồi gửi từng bước.
    private mutating func gesture(
        at location: CGPoint, value: Double, phase: GesturePhase, in space: some RemoteCoordinateSpace,
        _ make: (Double, AppleGesturePhase, UInt16, UInt16) -> AppleInputEvent
    ) -> [ClientMessage] {
        guard let target = space.remotePixel(forView: location, clamped: true) else { return [] }
        var messages: [ClientMessage] = []
        if phase == .began, buttons == 0 {
            pointer = target
            messages.append(pointerMessage(target))
        }
        let x = clampedX(pointer.x), y = clampedY(pointer.y)
        // Mac nhận began và ended không mang giá trị (đúng dạng đã thử thật); phần thay đổi UIKit báo kèm began/ended (ngón đã
        // chụm một chút trước khi bộ nhận diện bắt đầu) đi riêng thành một bước changed để không mất.
        if phase == .began { messages.append(.appleEvent(make(0, .began, x, y))) }
        if phase == .changed || value != 0 { messages.append(.appleEvent(make(value, .changed, x, y))) }
        if phase == .ended { messages.append(.appleEvent(make(0, .ended, x, y))) }
        return messages
    }

    private mutating func pencil(_ action: PencilAction, in space: some RemoteCoordinateSpace) -> [ClientMessage] {
        switch action {
        case .press(let point):
            guard let target = absoluteTarget(point, in: space) else { return [] }
            let move = pointerMessage(target)
            buttons |= Self.leftButton
            return [move, pointerMessage(target)]
        case .move(let point):
            guard let target = absoluteTarget(point, in: space) else { return [] }
            return [pointerMessage(target)]
        case .release(let point):
            buttons &= ~Self.leftButton
            let target = absoluteTarget(point, in: space) ?? pointer
            return [pointerMessage(target)]
        case .click(let point), .rightClick(let point):
            // Chạm bút vào viền đen ngoài màn hình Mac: không nhấp (như ngón tay).
            guard let pixel = space.remotePixel(forView: point, clamped: false) else { return [] }
            pointer = pixel
            if case .rightClick = action { return click(Self.rightButton, at: pixel) }
            return click(Self.leftButton, at: pixel)
        }
    }

    // MARK: - Nhấp, kéo, cuộn

    private func pointerMessage(_ target: (x: Int, y: Int)) -> ClientMessage {
        .pointerEvent(buttons: buttons, x: clampedX(target.x), y: clampedY(target.y))
    }

    /// Một lần nhấp: di chuyển tới vị trí, nhấn, nhả.
    private mutating func click(_ button: UInt8, at target: (x: Int, y: Int)) -> [ClientMessage] {
        let x = clampedX(target.x), y = clampedY(target.y)
        return [
            .pointerEvent(buttons: buttons, x: x, y: y),
            .pointerEvent(buttons: buttons | button, x: x, y: y),
            .pointerEvent(buttons: buttons, x: x, y: y),
        ]
    }

    /// Nhấn giữ nút trái rồi kéo (dùng cho nhấn-giữ-rồi-kéo và cho "một ngón kéo = kéo thả").
    private mutating func dragStep(to location: CGPoint, phase: GesturePhase, in space: some RemoteCoordinateSpace) -> [ClientMessage] {
        switch phase {
        case .began:
            guard let target = target(at: location, in: space) else { return [] }
            lastLocation = location
            isDragging = true
            let move = pointerMessage(target)
            buttons |= Self.leftButton
            return [move, pointerMessage(target)]

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
            return [pointerMessage(target)]

        case .ended:
            guard isDragging else { return [] }
            isDragging = false
            lastLocation = nil
            buttons &= ~Self.leftButton
            return [pointerMessage(pointer)]
        }
    }

    /// Cuộn: gom quãng kéo, mỗi `scrollTickDistance` point ra một nấc bánh xe (nhấn rồi nhả nút 4 hoặc 5, 6, 7).
    /// - Parameter atLocation: cuộn tại `location` bất kể chế độ (chuột, trackpad của iPad: ở đó là con trỏ).
    private mutating func scroll(
        location: CGPoint, translation: CGPoint, phase: GesturePhase, in space: some RemoteCoordinateSpace,
        atLocation: Bool = false
    ) -> [ClientMessage] {
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

        // Chạm trực tiếp: cuộn tại chỗ hai ngón đang đặt. Trackpad: tại con trỏ.
        let anchor = (policy.mode == .directTouch || atLocation ? space.remotePixel(forView: location, clamped: true) : nil) ?? pointer
        let tick = policy.scrollTickDistance
        var messages: [ClientMessage] = []

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

        // Ngón đi lên (translation.y âm) với cuộn tự nhiên nghĩa là nội dung đi lên, tức cuộn xuống (nút 5).
        let down = policy.naturalScrolling ? -verticalTicks : verticalTicks
        let right = policy.naturalScrolling ? -horizontalTicks : horizontalTicks
        if down != 0 || right != 0 { pointer = anchor }
        messages += wheel(down > 0 ? Self.wheelDown : Self.wheelUp, count: abs(down), at: anchor)
        messages += wheel(right > 0 ? Self.wheelRight : Self.wheelLeft, count: abs(right), at: anchor)
        return messages
    }

    /// Cuộn kiểu trackpad của Mac: began, changed..., ended; nếu sau ended còn bước (quán tính của app) thì thành pha quán tính
    /// begin, continue..., end, để Mac tự xử lý như vuốt trackpad thật (nảy ở mép, cuộn tiếp trong ứng dụng).
    private mutating func appleScroll(
        location: CGPoint, translation: CGPoint, phase: GesturePhase, in space: some RemoteCoordinateSpace, atLocation: Bool
    ) -> [ClientMessage] {
        let anchor = (policy.mode == .directTouch || atLocation ? space.remotePixel(forView: location, clamped: true) : nil) ?? pointer
        let x = clampedX(anchor.x), y = clampedY(anchor.y)
        func event(_ dx: Int32, _ dy: Int32, _ phase: AppleScroll.Phase, _ momentum: AppleScroll.Momentum) -> ClientMessage {
            .appleEvent(.scroll(AppleScroll(deltaX: dx, deltaY: dy, phase: phase, momentum: momentum, x: x, y: y)))
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
            case .momentum: return [event(0, 0, .none, .end)]
            case .idle: return []
            }
        case .changed:
            break
        }
        // Quãng theo point của Mac, giữ phần lẻ cho lần sau để cuộn chậm không bị mất.
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
            return [event(dx, dy, .none, .begin)]
        case .momentum:
            return dx == 0 && dy == 0 ? [] : [event(dx, dy, .none, .continue)]
        }
    }

    private func wheel(_ button: UInt8, count: Int, at target: (x: Int, y: Int)) -> [ClientMessage] {
        let x = clampedX(target.x), y = clampedY(target.y)
        return (0..<count).flatMap { _ in
            [.pointerEvent(buttons: buttons | button, x: x, y: y), .pointerEvent(buttons: buttons, x: x, y: y)]
        }
    }

    private func clampedX(_ value: Int) -> UInt16 { UInt16(clamping: max(value, 0)) }
    private func clampedY(_ value: Int) -> UInt16 { UInt16(clamping: max(value, 0)) }
}
