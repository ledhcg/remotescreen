import ConnectionKit
import Foundation
import InputKit
import Network
import Observation
import RFBKit
import RemoteDisplay
import SessionKit
import UIKit

/// Điều khiển vòng đời một kết nối: mở, nhận cập nhật, đẩy lên view, chuyển thao tác của người dùng sang Mac,
/// tự nối lại khi đứt, ngắt.
///
/// Chạy trên main actor. Phần giải mã nặng nằm trong `RFBSession` (một actor riêng), nên main thread chỉ nhận
/// một bản sao khung hình (copy-on-write) rồi đẩy các vùng thay đổi lên GPU.
@MainActor
@Observable
final class SessionController {
    enum State: Equatable {
        case idle
        case connecting
        case connected(name: String)
        /// Đã từng nối được nhưng bị đứt, đang thử lại. Màn hình cuối vẫn hiện, thao tác bị bỏ qua.
        case reconnecting(name: String, attempt: Int, of: Int)
        case failed(String)
    }

    private(set) var state: State = .idle
    /// Cảnh báo an toàn của phiên hiện tại (mật khẩu VNC yếu, không xác thực), hiện suốt phiên.
    private(set) var securityWarning: String?
    private(set) var touchMode: TouchMode = .directTouch
    private(set) var isKeyboardVisible = false
    /// Vừa màn hình, lấp đầy hoặc điểm ảnh gốc. Lưu giữa các lần mở app.
    private(set) var displayMode: DisplayMode
    private(set) var isKeyBarVisible = false
    /// "Chỉ xem" (Observe): không gửi chuột và phím tới Mac, chỉ nhận hình. Clipboard cũng không bị đẩy lên Mac.
    private(set) var isViewOnly = false
    /// Vẽ con trỏ của Mac lên màn hình (server không vẽ nó vào khung hình).
    private(set) var isRemoteCursorVisible = true
    /// Bảng thống kê luồng hình (khung/s, Mbit/s, ms giải mã, ms vẽ): để biết lag do mạng, giải mã hay vẽ.
    private(set) var isStatsVisible = false
    private(set) var streamStats: StreamStats?
    /// Phím bổ trợ đang nhấn trên Mac do sidebar hay thanh phím phụ: giữ, dính một lần hoặc khóa. Phím không có ở đây là `.up`.
    private(set) var modifierStates: [StickyModifier: ModifierState] = [:]
    /// Sidebar phím bổ trợ kiểu Sidecar: trái, phải hay ẩn. Lưu giữa các lần mở app.
    private(set) var sidebarPosition: SidebarPosition
    /// Server đang nối là `screensharingd` của Apple: mới có cuộn mượt và chụm/xoay trên Mac (message 23).
    private(set) var isAppleServer = false
    /// Cuộn kiểu trackpad có quán tính trên Mac (message 23 loại 11), mặc định bật. Đã thử trên Mac thật: ứng dụng nhận cuộn
    /// chính xác theo point, đủ pha và quán tính. Tắt thì cuộn bằng nấc bánh xe RFB chuẩn.
    private(set) var smoothScroll: Bool
    /// Chụm/xoay hai ngón: phóng khung nhìn trên iPad (mặc định) hay gửi lên Mac (message 23 loại 3, 5 bản 2, đã thử thật).
    private(set) var pinchSendsToMac: Bool
    /// Chạm hai lần lên Apple Pencil làm gì. Lưu giữa các lần mở app.
    private(set) var pencilDoubleTapAction: PencilDoubleTapAction
    /// Sau nét bút đầu tiên, ngón tay chỉ cuộn và phóng (như Sidecar). Mặc định theo cài đặt hệ thống "Chỉ vẽ bằng Apple Pencil".
    private(set) var fingersOnlyScrollWithPencil: Bool

    let clipboard: ClipboardBridge
    /// Chế độ chất lượng hình, lưu lại giữa các lần mở app (`UserDefaults`).
    private(set) var qualityMode: QualityMode
    /// Đang nối lại ngắn để áp dụng độ sâu màu mới (người dùng vừa đổi chế độ chất lượng). Dùng để banner nói đúng việc đang làm.
    private(set) var isApplyingQuality = false
    /// Trần khung hình đang áp dụng (`nil` là không giới hạn), để hiện trong bảng thống kê.
    private(set) var currentMaxFramesPerSecond: Int?
    /// Khi nào thử nối lại, và khi nào thôi. Đổi `ReconnectPolicy.standard` để chỉnh trải nghiệm.
    @ObservationIgnored var reconnectPolicy = ReconnectPolicy.standard

    /// Quay lại từ nền sau lâu hơn mức này thì coi kết nối cũ là đã chết và nối lại ngay, thay vì chờ hệ điều hành báo lỗi.
    static let staleAfterBackground: TimeInterval = 10
    /// Phiên sống ít nhất chừng này thì lần đứt kế tiếp được tính lại từ đầu bảng giãn cách. Chặn vòng "nối được rồi đứt ngay".
    static let stableSessionDuration: Duration = .seconds(30)

    private struct Request {
        let target: SavedConnection.Target
        let username: String
        let password: String
        let onConnected: (@MainActor () -> Void)?
    }

    @ObservationIgnored private var governor = AdaptiveGovernor()
    /// Đếm của cửa sổ thống kê hiện tại; vòng nhận cộng vào, một đồng hồ riêng đọc mỗi giây (kể cả khi màn hình đứng yên).
    @ObservationIgnored private var pacing = FramePacing()
    @ObservationIgnored private var windowUpdates = 0
    @ObservationIgnored private var windowDraw = Duration.zero
    /// Cỡ khung nhìn theo pixel thiết bị, và tỉ lệ thu nhỏ đã nhờ server áp dụng cho phiên hiện tại (`nil` là chưa gửi, tức 1).
    @ObservationIgnored private var viewPixelSize = CGSize.zero
    @ObservationIgnored private var serverScaleSent: Double?
    @ObservationIgnored private var scalingTask: Task<Void, Never>?
    /// Độ sâu màu của phiên đang mở hoặc vừa mở: so với chế độ mới để biết đổi chế độ có cần nối lại không.
    @ObservationIgnored private var sessionDepth: ColorDepth?
    /// Lần đứt kế tiếp là do ta chủ động nối lại để đổi chất lượng: thử lại ngay, không chờ và không tính vào số lần thử.
    @ObservationIgnored private var reconnectingForQuality = false
    @ObservationIgnored private let defaults: UserDefaults
    static let qualityModeKey = "qualityMode"
    static let displayModeKey = "displayMode"
    static let sidebarPositionKey = "sidebarPosition"
    static let pencilDoubleTapKey = "pencilDoubleTap"
    static let smoothScrollKey = "appleSmoothScroll"
    static let pinchToMacKey = "pinchSendsToMac"
    static let pencilFingersKey = "pencilFingersOnlyScroll"

    /// `UserDefaults` dùng cho cài đặt của phiên. Bản debug cho phép UI test cô lập qua `RFB_DEFAULTS_SUITE=<tên>`, để chế độ
    /// chất lượng một bài test chọn không dính sang bài khác (mỗi bài dùng một tên riêng).
    static func environmentDefaults() -> UserDefaults {
        #if DEBUG
        if let suite = ProcessInfo.processInfo.environment["RFB_DEFAULTS_SUITE"], let defaults = UserDefaults(suiteName: suite) {
            return defaults
        }
        #endif
        return .standard
    }

    @ObservationIgnored private var request: Request?
    @ObservationIgnored private var session: RFBSession?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private weak var screenView: RemoteScreenView?
    /// Hình con trỏ mới nhất, vì server chỉ gửi khi hình đổi: view tạo sau vẫn phải có.
    @ObservationIgnored private var latestCursor: CursorImage?

    @ObservationIgnored private var wakeRequested = false
    @ObservationIgnored private var backgroundedAt: Date?
    @ObservationIgnored private var networkMonitor: NWPathMonitor?
    @ObservationIgnored private var networkWasDown = false

    /// CHỈ BẢN DEBUG: bỏ mọi sự kiện chuột và phím trước khi gửi, chỉ cho clipboard đi qua. Để thử clipboard với một Mac
    /// thật mà không thể điều khiển nó nhầm (kể cả ⌘V cũng chỉ gửi clipboard chứ không dán thật). Bật bằng `RFB_DROP_INPUT=1`.
    @ObservationIgnored private var dropsInputForTesting = false
    /// CHỈ BẢN DEBUG: mở sẵn bảng thống kê luồng hình mỗi phiên (`RFB_STATS=1`), để đo trên iPad khi không bấm được menu.
    @ObservationIgnored private var showsStatsByDefault = false

    init(clipboard: ClipboardBridge = ClipboardBridge(pasteboard: SystemPasteboard()), defaults: UserDefaults = .standard) {
        self.clipboard = clipboard
        self.defaults = defaults
        qualityMode = defaults.string(forKey: Self.qualityModeKey).flatMap(QualityMode.init(rawValue:)) ?? .default
        displayMode = defaults.string(forKey: Self.displayModeKey).flatMap(DisplayMode.init(rawValue:)) ?? .default
        sidebarPosition = defaults.string(forKey: Self.sidebarPositionKey).flatMap(SidebarPosition.init(rawValue:)) ?? .default
        smoothScroll = defaults.object(forKey: Self.smoothScrollKey) as? Bool ?? true
        pinchSendsToMac = defaults.bool(forKey: Self.pinchToMacKey)
        pencilDoubleTapAction = defaults.string(forKey: Self.pencilDoubleTapKey).flatMap(PencilDoubleTapAction.init(rawValue:))
            ?? .secondaryClick
        fingersOnlyScrollWithPencil = defaults.object(forKey: Self.pencilFingersKey) as? Bool
            ?? UIPencilInteraction.prefersPencilOnlyDrawing
        currentMaxFramesPerSecond = qualityMode.initialMaxFramesPerSecond
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        dropsInputForTesting = environment["RFB_DROP_INPUT"] == "1"
        isKeyBarVisible = environment["RFB_KEYBAR"] == "1"
        showsStatsByDefault = environment["RFB_STATS"] == "1"
        if let value = environment["RFB_SMOOTH_SCROLL"] { smoothScroll = value == "1" }
        if environment["RFB_PINCH_TO_MAC"] == "1" { pinchSendsToMac = true }
        if let position = environment["RFB_SIDEBAR"].flatMap(SidebarPosition.init(rawValue:)) { sidebarPosition = position }
        if let mode = environment["RFB_QUALITY"].flatMap(QualityMode.init(rawValue:)) {
            qualityMode = mode
            currentMaxFramesPerSecond = mode.initialMaxFramesPerSecond
        }
        isStatsVisible = showsStatsByDefault
        #endif
    }

    /// Gắn view hiển thị. Nếu đã có khung hình thì hiển thị ngay.
    func attach(_ view: RemoteScreenView) {
        screenView = view
        // Thao tác người dùng đi qua hàng đợi có thứ tự của phiên, nên "nhấn" luôn tới Mac trước "nhả".
        view.onInput = { [weak self] messages in self?.sendUserInput(messages) }
        view.touchPolicy = touchPolicy
        view.pinchSendsToMac = pinchSendsToMac && isAppleServer
        view.showsRemoteCursor = isRemoteCursorVisible
        view.displayMode = displayMode
        view.acceptsRemoteInput = !isViewOnly
        view.onPixelSizeChange = { [weak self] size in self?.viewPixelSizeChanged(size) }
        view.drawsLocalCursor = sessionDepth != .reduced // 16 bit: server tự vẽ con trỏ, vẽ thêm là thành hai con trỏ
        view.onContentPresented = { [weak self] time, merged in self?.pacing.recordPresent(at: time, mergedUpdates: merged) }
        view.onModifierStatesChange = { [weak self] states in self?.modifierStates = states }
        view.fingersOnlyScrollWithPencil = fingersOnlyScrollWithPencil
        view.onPencilDoubleTap = { [weak self] in self?.pencilDoubleTapped() }
        if let latestCursor { view.setCursor(latestCursor) }
        // View tạo sau khi khung hình đã tới (SwiftUI dựng view chậm hơn việc nhận dữ liệu): lấy khung hiện tại từ session.
        // KHÔNG giữ một bản sao khung hình trong controller: bản sao giữ chung bộ nhớ với session, nên mọi cập nhật sau đó buộc
        // session sao chép nguyên 14,7 MB (màn hình 2560x1440) dù chỉ đổi vài pixel, ví dụ lúc gõ chữ.
        if let session {
            Task { @MainActor [weak view] in
                let frame = await session.framebuffer
                view?.display(frame)
            }
        }
    }

    /// Thao tác của người dùng. Đang nối lại thì không có phiên nào để gửi tới: bỏ qua thay vì ghi vào một kết nối đã chết.
    private func sendUserInput(_ messages: [ClientMessage]) {
        guard let session, !isViewOnly else { return }
        var outgoing = clipboard.prepareOutgoing(messages)
        #if DEBUG
        if dropsInputForTesting {
            outgoing = outgoing.filter {
                switch $0 {
                case .pointerEvent, .keyEvent: false
                default: true
                }
            }
        }
        #endif
        session.post(outgoing)
    }

    // MARK: - Kết nối

    func connect(host: String, port: UInt16, username: String, password: String, onConnected: (@MainActor () -> Void)? = nil) {
        connect(target: .host(host, port: port), username: username, password: password, onConnected: onConnected)
    }

    /// - Parameter onConnected: chạy trên main actor ngay khi kết nối thành công lần đầu (ví dụ để lưu máy vào danh sách).
    ///   Không chạy lại ở các lần tự nối lại.
    func connect(target: SavedConnection.Target, username: String, password: String, onConnected: (@MainActor () -> Void)? = nil) {
        switch state {
        case .connecting, .reconnecting: return
        default: break
        }
        request = Request(target: target, username: username, password: password, onConnected: onConnected)
        resetSessionControls()
        state = .connecting
        task?.cancel()
        startNetworkWatch()
        task = Task { [weak self] in await self?.connectionLoop() }
    }

    func disconnect() {
        screenView?.releaseAllInput() // nhả phím và nút chuột trước khi đóng, để Mac không bị kẹt
        task?.cancel()
        stopNetworkWatch()
        request = nil
        let closing = session
        session = nil
        securityWarning = nil
        clipboard.sessionEnded()
        latestCursor = nil
        reconnectingForQuality = false
        isApplyingQuality = false
        serverScaleSent = nil
        scalingTask?.cancel()
        resetSessionControls()
        state = .idle
        Task { await closing?.close() }
    }

    /// Đang có phiên sống để nhận thao tác (không phải lúc đang nối hay nối lại).
    var isLive: Bool {
        if case .connected = state { return true }
        return false
    }

    /// Cửa sổ của app mất tiêu điểm (chuyển sang cửa sổ khác của chính app, Stage Manager): lần nhả phím và nút sẽ không tới
    /// view này, nên nhả ngay. Thông báo cấp app (`willResignActive`) không bắn khi chuyển giữa các cửa sổ của cùng app.
    func sceneDidDeactivate() {
        screenView?.releaseAllInput()
    }

    /// Đóng thông báo lỗi kết nối để quay về trạng thái chờ. Chỉ có tác dụng khi đang ở `.failed`.
    func dismissFailure() {
        if case .failed = state { state = .idle }
    }

    /// Mỗi phiên bắt đầu từ cấu hình mặc định: view mới luôn ở chế độ vừa màn hình, chưa bật bàn phím, và đang điều khiển.
    /// Không đặt lại thì nút trên thanh công cụ báo "bật" trong khi view mới chưa theo.
    private func resetSessionControls() {
        isViewOnly = false
        isStatsVisible = showsStatsByDefault
        streamStats = nil
        isRemoteCursorVisible = true
        isKeyboardVisible = false
        isKeyBarVisible = false
        modifierStates = [:]
    }

    /// Mở phiên; khi một phiên đã từng sống mà đứt thì chờ rồi mở lại theo `reconnectPolicy`.
    /// Lần mở đầu tiên thất bại thì báo ngay (sai địa chỉ hay mật khẩu không nên bị lặp lại âm thầm).
    private func connectionLoop() async {
        guard let request else { return }
        let hasUsername = !request.username.isEmpty
        var retriesMade = 0
        var everConnected = false
        var name = ""

        while !Task.isCancelled {
            var current: RFBSession?
            var connectedAt: ContinuousClock.Instant?
            do {
                let depth = qualityMode.colorDepth
                let opened = try await RFBConnection.open(
                    endpoint: request.target.endpoint, credentials: RFBCredentials(username: request.username, password: request.password),
                    pixelFormat: depth.pixelFormat
                )
                sessionDepth = depth
                current = opened
                guard !Task.isCancelled else {
                    await opened.close()
                    return
                }
                session = opened
                name = opened.serverInfo.name
                state = .connected(name: name)
                securityWarning = ConnectionSecurityNotice.sessionWarning(for: opened.securityType)
                isApplyingQuality = false
                connectedAt = .now
                clipboard.sessionStarted(flavor: opened.flavor) { [weak self] messages in self?.session?.post(messages) }
                isAppleServer = opened.flavor == .apple
                applyServerFeatures()
                // Người dùng đổi chế độ chất lượng trong lúc lần nối này đang chạy: độ sâu màu vừa mở đã cũ. Nối lại ngay.
                if qualityMode.colorDepth != depth {
                    isApplyingQuality = true
                    reconnectingForQuality = true
                    forceReconnect()
                }
                if !everConnected {
                    everConnected = true
                    request.onConnected?()
                }
                try await run(opened)
            } catch {
                // Ngắt chủ động làm luồng đóng và ném lỗi, đó không phải lỗi cần báo.
                if Task.isCancelled { return }
                session = nil
                clipboard.sessionEnded()
                screenView?.releaseAllInput() // xóa trạng thái phím/chạm cũ (thao tác bị bỏ vì không còn phiên)
                await current?.close()
                // Người dùng bấm Ngắt trong lúc đang đóng: `disconnect()` đã đặt trạng thái, đừng ghi đè nó.
                if Task.isCancelled { return }

                guard everConnected else {
                    stopNetworkWatch()
                    self.request = nil // không giữ mật khẩu trong bộ nhớ sau khi đã thất bại
                    state = .failed(ConnectionFailureMessage.text(for: error, hasUsername: hasUsername))
                    return
                }
                if reconnectingForQuality {
                    // Ta tự đóng phiên để đổi độ sâu màu: nối lại ngay, không chờ, và không tính là lần thử lại do mất kết nối.
                    reconnectingForQuality = false
                    retriesMade = 0
                    state = .reconnecting(name: name, attempt: 1, of: reconnectPolicy.maxAttempts)
                    continue
                }
                isApplyingQuality = false
                if let connectedAt, ContinuousClock.now - connectedAt > Self.stableSessionDuration { retriesMade = 0 }

                switch reconnectPolicy.decision(after: error, attemptsMade: retriesMade) {
                case .retry(let delay, let attempt):
                    retriesMade = attempt
                    state = .reconnecting(name: name, attempt: attempt, of: reconnectPolicy.maxAttempts)
                    await wait(delay)
                case .giveUp(let reason):
                    stopNetworkWatch()
                    self.request = nil
                    latestCursor = nil
                    state = .failed(ConnectionFailureMessage.giveUp(
                        reason, error: error, name: name, attempts: retriesMade, hasUsername: hasUsername
                    ))
                    return
                }
            }
        }
    }

    /// Chờ `delay`, hoặc ít hơn nếu có tín hiệu: mạng vừa có lại, hay app vừa quay lại từ nền.
    private func wait(_ delay: Duration) async {
        wakeRequested = false
        let end = ContinuousClock.now + delay
        while ContinuousClock.now < end, !wakeRequested, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    // MARK: - Nền và mạng

    func appDidEnterBackground() {
        backgroundedAt = Date()
    }

    func appDidBecomeActive() {
        defer { backgroundedAt = nil }
        switch state {
        case .reconnecting:
            wakeRequested = true // người dùng đã quay lại: thử ngay, đừng chờ hết giãn cách
        case .connected:
            if let backgroundedAt, Date().timeIntervalSince(backgroundedAt) > Self.staleAfterBackground {
                forceReconnect()
            }
        default:
            break
        }
    }

    /// Đóng phiên hiện tại để vòng kết nối coi như bị đứt và nối lại. Dùng khi nghi kết nối đã chết nhưng hệ điều hành chưa báo.
    func forceReconnect() {
        guard let old = session else { return }
        // Nhả phím, nút và phím dính TRƯỚC khi đóng (phiên vẫn còn nên các lần nhả còn tới Mac). Sau khi đóng thì chúng bị bỏ
        // trong khi giao diện đã coi là nhả, và ⌘ có thể kẹt trên Mac.
        screenView?.releaseAllInput()
        Task { await old.close() }
    }

    private func startNetworkWatch() {
        stopNetworkWatch()
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            Task { @MainActor in self?.networkChanged(satisfied: satisfied) }
        }
        monitor.start(queue: DispatchQueue(label: "RemoteScreen.NetworkWatch"))
        networkMonitor = monitor
    }

    private func stopNetworkWatch() {
        networkMonitor?.cancel()
        networkMonitor = nil
        networkWasDown = false
    }

    /// Mạng có lại sau khi mất: nếu đang chờ nối lại thì thử ngay.
    private func networkChanged(satisfied: Bool) {
        if satisfied, networkWasDown { wakeRequested = true }
        networkWasDown = !satisfied
    }

    // MARK: - Điều khiển giao diện

    func toggleTouchMode() {
        touchMode = touchMode == .directTouch ? .trackpad : .directTouch
        screenView?.touchPolicy = touchPolicy
    }

    /// Cách chạm hiện tại, kèm cuộn mượt khi server là Apple và người dùng bật.
    private var touchPolicy: TouchPolicy {
        var policy = TouchPolicy(mode: touchMode)
        policy.appleSmoothScroll = smoothScroll && isAppleServer
        return policy
    }

    /// Server vừa đổi (nối mới, nối lại): áp lại những gì phụ thuộc server Apple.
    private func applyServerFeatures() {
        screenView?.touchPolicy = touchPolicy
        screenView?.pinchSendsToMac = pinchSendsToMac && isAppleServer
    }

    func setSmoothScroll(_ enabled: Bool) {
        smoothScroll = enabled
        defaults.set(enabled, forKey: Self.smoothScrollKey)
        applyServerFeatures()
    }

    func setPinchSendsToMac(_ enabled: Bool) {
        pinchSendsToMac = enabled
        defaults.set(enabled, forKey: Self.pinchToMacKey)
        applyServerFeatures()
    }

    func toggleKeyboard() {
        isKeyboardVisible.toggle()
        screenView?.isSoftwareKeyboardVisible = isKeyboardVisible
    }

    func toggleKeyBar() {
        isKeyBarVisible.toggle()
    }

    func toggleModifier(_ modifier: StickyModifier) {
        screenView?.toggleModifier(modifier)
    }

    func press(_ key: VirtualKey) {
        screenView?.press(key)
    }

    func modifierTouchDown(_ modifier: StickyModifier) {
        screenView?.modifierTouchDown(modifier)
    }

    func modifierTouchUp(_ modifier: StickyModifier) {
        screenView?.modifierTouchUp(modifier)
    }

    /// Nút Hoàn tác của sidebar: ⌘Z trên Mac (⇧ đang dính thì thành ⌘⇧Z, làm lại).
    func undo() {
        screenView?.pressCommandChord("z")
    }

    func setPencilDoubleTapAction(_ action: PencilDoubleTapAction) {
        pencilDoubleTapAction = action
        defaults.set(action.rawValue, forKey: Self.pencilDoubleTapKey)
    }

    func setFingersOnlyScrollWithPencil(_ enabled: Bool) {
        fingersOnlyScrollWithPencil = enabled
        defaults.set(enabled, forKey: Self.pencilFingersKey)
        screenView?.fingersOnlyScrollWithPencil = enabled
    }

    private func pencilDoubleTapped() {
        switch pencilDoubleTapAction {
        case .secondaryClick: screenView?.secondaryClickAtPointer()
        case .toggleKeyboard: toggleKeyboard()
        case .nothing: break
        }
    }

    func setSidebarPosition(_ position: SidebarPosition) {
        guard position != sidebarPosition else { return }
        // Ẩn sidebar thì nhả phím bổ trợ đang dính hay khóa: không còn chỗ nào thấy và bỏ được chúng nữa.
        if position == .hidden, !isKeyBarVisible { screenView?.releaseModifiers() }
        sidebarPosition = position
        defaults.set(position.rawValue, forKey: Self.sidebarPositionKey)
    }

    /// Chuyển giữa điều khiển và chỉ xem. Nhả mọi phím và nút đang giữ **trước** khi chặn, để Mac không bị kẹt phím.
    func setViewOnly(_ viewOnly: Bool) {
        guard viewOnly != isViewOnly else { return }
        if viewOnly {
            screenView?.releaseAllInput()
            if isKeyboardVisible { toggleKeyboard() }
            isKeyBarVisible = false
        }
        isViewOnly = viewOnly
        screenView?.acceptsRemoteInput = !viewOnly
    }

    /// Đổi chế độ chất lượng. Nhịp khung hình đổi ngay; độ sâu màu không đổi được giữa phiên (xem `ColorDepth`) nên nếu cần thì
    /// nối lại ngắn (khoảng một giây, màn hình cuối vẫn hiện) để áp dụng.
    func setQualityMode(_ mode: QualityMode) {
        guard mode != qualityMode else { return }
        qualityMode = mode
        defaults.set(mode.rawValue, forKey: Self.qualityModeKey)
        governor = AdaptiveGovernor()
        currentMaxFramesPerSecond = mode.initialMaxFramesPerSecond
        guard let session else { return } // chưa có phiên: áp dụng ở lần kết nối kế tiếp
        if sessionDepth != mode.colorDepth {
            isApplyingQuality = true
            reconnectingForQuality = true
            forceReconnect()
        } else {
            let interval = currentMaxFramesPerSecond.minimumUpdateInterval
            Task { await session.setMinimumUpdateInterval(interval) }
            applyServerScaling() // "hiệu năng tốt nhất" bật thu nhỏ phía server, các chế độ khác tắt
        }
    }

    /// Dòng thống kê kèm cấu hình đang áp dụng, ví dụ "20 khung/s · 12,3 Mbit/s · giải mã 1,9 ms · vẽ 0,7 ms · 16-bit · ≤20 khung/s".
    var statsLine: String {
        var line = streamStats?.summary ?? "Đang đo…"
        if sessionDepth == .reduced { line += " · 16 bit" }
        if let cap = currentMaxFramesPerSecond { line += " · ≤\(cap) khung/s" }
        return line
    }

    func setStatsVisible(_ visible: Bool) {
        isStatsVisible = visible
        if !visible { streamStats = nil }
    }

    func setRemoteCursorVisible(_ visible: Bool) {
        isRemoteCursorVisible = visible
        screenView?.showsRemoteCursor = visible
    }

    func setDisplayMode(_ mode: DisplayMode) {
        guard mode != displayMode else { return }
        displayMode = mode
        defaults.set(mode.rawValue, forKey: Self.displayModeKey)
        screenView?.displayMode = mode
        applyServerScaling()
    }

    // MARK: - Thu nhỏ phía server (chế độ theo độ phân giải thiết bị)

    private func viewPixelSizeChanged(_ size: CGSize) {
        viewPixelSize = size
        // Xoay máy hay kéo Split View đổi cỡ nhiều lần liền: chờ bố cục yên rồi gửi một lần.
        scalingTask?.cancel()
        scalingTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self?.applyServerScaling()
        }
    }

    /// Nhờ server Apple thu nhỏ hình bằng đúng cỡ pixel của khung nhìn (message loại 8), hoặc trả về cỡ gốc khi rời chế độ đó.
    /// Server khác: không làm gì (chế độ `.device` khi đó như vừa màn hình).
    private func applyServerScaling() {
        guard let session, session.flavor == .apple else { return }
        let remote = CGSize(width: Double(session.serverInfo.width), height: Double(session.serverInfo.height))
        let wanted = displayMode.serverScale(remote: remote, viewPixels: viewPixelSize)
            ?? (qualityMode.prefersServerScaling ? DisplayMode.device.serverScale(remote: remote, viewPixels: viewPixelSize) : nil)
            ?? 1
        if let sent = serverScaleSent, abs(sent - wanted) < 0.002 { return }
        if serverScaleSent == nil, wanted == 1 { return } // phiên mới vốn ở cỡ gốc
        serverScaleSent = wanted
        session.post([.appleServerScaling(wanted)])
    }

    func setTouchMode(_ mode: TouchMode) {
        guard mode != touchMode else { return }
        toggleTouchMode()
    }

    // MARK: - Vòng nhận

    private func run(_ session: RFBSession) async throws {
        // Session tự xin cập nhật kế tiếp ngay khi nhận tiêu đề của cập nhật hiện tại (`pipelinesUpdateRequests`),
        // nên vòng này không gọi `requestUpdate`: chỉ nhận, giải mã, vẽ.
        //
        // Ở 16 bit KHÔNG xin hình con trỏ riêng: RFC nói pixel con trỏ theo định dạng client, nhưng chưa đo được server Apple gửi
        // nó ở định dạng nào (nó chỉ gửi con trỏ sau khi người xem đã điều khiển chuột). Không xin thì server vẽ con trỏ vào
        // khung hình: tệ nhất là con trỏ trễ một chút, không bao giờ lệch luồng và rớt phiên.
        let encodings: [RFBEncoding] = sessionDepth == .reduced
            ? [.zrle, .copyRect, .desktopSize]
            : [.zrle, .copyRect, .cursor, .desktopSize]
        try await session.start(encodings: encodings)
        screenView?.drawsLocalCursor = sessionDepth != .reduced
        pacing = FramePacing()
        // Phiên mới: bộ điều khiển tự động bắt đầu lại từ bậc đầy đủ, trừ khi chế độ có trần cố định.
        governor = AdaptiveGovernor()
        currentMaxFramesPerSecond = qualityMode.initialMaxFramesPerSecond
        await session.setMinimumUpdateInterval(currentMaxFramesPerSecond.minimumUpdateInterval)
        serverScaleSent = nil
        applyServerScaling()

        windowUpdates = 0
        windowDraw = .zero
        // Thống kê và bộ điều khiển tự động chạy theo đồng hồ riêng: màn hình đứng yên thì không có sự kiện nào, nhưng vẫn phải
        // báo 0 khung/s và vẫn tính là "nhẹ" để trả lại tốc độ đầy đủ.
        let statsTask = Task { [weak self] in await self?.measureStats(of: session) }
        defer { statsTask.cancel() }

        while !Task.isCancelled {
            switch try await session.nextEvent() {
            case .framebufferUpdate(let dirty, let cursor):
                if let cursor {
                    latestCursor = cursor
                    screenView?.setCursor(cursor)
                }
                // Bản sao copy-on-write, thả ngay sau khi vẽ xong (không giữ lại) để session không phải sao chép cả bộ đệm.
                let drawStart = ContinuousClock.now
                let frame = await session.framebuffer
                screenView?.display(frame, dirty: dirty.isEmpty ? nil : dirty)
                windowDraw += ContinuousClock.now - drawStart
                windowUpdates += 1
            case .clipboard(let transfer):
                clipboard.receive(transfer)
            case .serverCutText(let text):
                clipboard.receive(cutText: text)
            case .clipboardSkipped(let bytes):
                clipboard.noteSkipped(bytes: bytes)
            case .bell, .colourMapIgnored:
                break
            }
        }
    }

    /// Mỗi giây: tính số liệu từ phần chênh của `session.statistics` và các đếm của vòng nhận, rồi cho bộ điều khiển tự động xem.
    private func measureStats(of session: RFBSession) async {
        var baseline = await session.statistics
        var windowStart = ContinuousClock.now
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            let now = ContinuousClock.now
            let snapshot = await session.statistics
            var measured = StreamStats.measure(
                updates: windowUpdates,
                wireBytes: snapshot.payloadBytes.values.reduce(0, +) - baseline.payloadBytes.values.reduce(0, +),
                decode: snapshot.decodeTime - baseline.decodeTime,
                draw: windowDraw,
                over: now - windowStart
            )
            if windowUpdates == 0 { pacing.resetBaseline() } // màn hình đứng yên không phải là giật
            measured?.pacing = pacing.drain()
            windowUpdates = 0
            windowDraw = .zero
            baseline = snapshot
            windowStart = now
            if isStatsVisible {
                streamStats = measured
                #if DEBUG
                // Ra console của thiết bị (devicectl --console) để đọc số liệu chính xác khi ảnh phản chiếu quá nhỏ.
                if measured != nil { print("RS_STATS \(statsLine)") }
                #endif
            }
            if qualityMode == .adaptive, let measured, let change = governor.observe(measured) {
                currentMaxFramesPerSecond = change.maxFramesPerSecond
                await session.setMinimumUpdateInterval(change.maxFramesPerSecond.minimumUpdateInterval)
            }
        }
    }
}
