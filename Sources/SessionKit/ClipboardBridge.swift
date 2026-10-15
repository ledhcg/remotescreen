import Foundation
import InputKit
import Observation
import RFBKit

/// Bảng clipboard của thiết bị, tách khỏi UIKit để test được.
///
/// Trên iOS, **đọc** nội dung clipboard do app khác sao chép làm hiện hộp thoại "cho phép dán", còn đọc `changeCount` và
/// `hasStrings` thì không. Cả `ClipboardBridge` lẫn bảng này đều được thiết kế để chỉ đọc nội dung khi thật sự cần gửi.
@MainActor
public protocol PasteboardAccess: AnyObject {
    var changeCount: Int { get }
    var hasStrings: Bool { get }
    /// Đọc có thể kích hoạt hộp thoại cho phép dán của iOS. Ghi thì không.
    var string: String? { get set }
    /// Ghi văn bản nhạy cảm (mật khẩu chép từ trình quản lý mật khẩu trên Mac): chỉ trên máy này (không qua Universal Clipboard)
    /// và tự hết hạn.
    func writeSensitive(_ text: String, expiresAfter seconds: TimeInterval)
}

extension PasteboardAccess {
    public func writeSensitive(_ text: String, expiresAfter seconds: TimeInterval) {
        string = text
    }
}

/// Đồng bộ clipboard giữa thiết bị và Mac.
///
/// - Server Apple: giao thức riêng, hỏi-đáp, có UTF-8 (`ClipboardTransfer`). Chiều Mac → thiết bị luôn do ta hỏi.
/// - Server RFB chuẩn: `ClientCutText` / `ServerCutText` (Latin-1). Server tự đẩy clipboard về khi nó đổi.
///
/// Hai chế độ:
/// - **Thủ công**: chỉ khi người dùng bấm nút (lấy từ Mac, hoặc nút Dán gửi lên Mac).
/// - **Tự động**: thêm hai phím tắt. ⌘C hoặc ⌘X trên Mac từ xa thì sau một lúc lấy clipboard Mac về thiết bị. ⌘V thì gửi clipboard
///   của thiết bị lên Mac ngay trước phím `v`, nhưng chỉ khi nó đã đổi từ lần đồng bộ trước.
@MainActor
@Observable
public final class ClipboardBridge {
    public enum Mode: String, CaseIterable, Sendable {
        case manual
        case shared
    }

    static let modeKey = "clipboardMode"

    public var mode: Mode {
        didSet {
            guard mode != oldValue else { return }
            defaults.set(mode.rawValue, forKey: Self.modeKey)
            detector.reset() // một ⌘ còn nhớ từ chế độ trước không được kích hoạt lệnh ở chế độ mới
        }
    }

    /// Thông báo ngắn cho người dùng, tự biến mất.
    public private(set) var notice: String?

    @ObservationIgnored private let pasteboard: any PasteboardAccess
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let copyDelay: Duration
    @ObservationIgnored private let noticeDuration: Duration
    @ObservationIgnored private var post: (@MainActor ([ClientMessage]) -> Void)?
    @ObservationIgnored private var flavor: ServerFlavor = .standard
    @ObservationIgnored private var detector = ClipboardShortcutDetector()
    @ObservationIgnored private var pendingTokens: Set<UInt32> = []
    /// `changeCount` của bảng clipboard ngay sau lần ta ghi vào hoặc gửi đi gần nhất. Khác nó nghĩa là người dùng đã sao chép
    /// thứ mới trên thiết bị, và cần gửi lên Mac khi dán.
    @ObservationIgnored private var syncedChangeCount: Int?
    /// Văn bản Mac gửi tới gần nhất qua giao thức chuẩn (server chuẩn tự đẩy, không cho hỏi).
    @ObservationIgnored private var latestStandardText: String?
    /// Server chuẩn tự đẩy clipboard bất cứ lúc nào, không cần người dùng làm gì. Chỉ trong khoảng ngắn sau khi chính người dùng
    /// sao chép trên Mac (⌘C/⌘X) ta mới coi bản đẩy tới là thứ họ muốn lấy về; ngoài khoảng đó nó chỉ được giữ lại.
    @ObservationIgnored private var standardPushAcceptedUntil: ContinuousClock.Instant?
    static let standardPushWindow: Duration = .seconds(3)
    @ObservationIgnored private var pullTask: Task<Void, Never>?
    @ObservationIgnored private var noticeTask: Task<Void, Never>?

    public init(
        pasteboard: any PasteboardAccess,
        defaults: UserDefaults = .standard,
        copyDelay: Duration = .milliseconds(350),
        noticeDuration: Duration = .seconds(2.5)
    ) {
        self.pasteboard = pasteboard
        self.defaults = defaults
        self.copyDelay = copyDelay
        self.noticeDuration = noticeDuration
        mode = defaults.string(forKey: Self.modeKey).flatMap(Mode.init(rawValue:)) ?? .shared
    }

    // MARK: - Vòng đời phiên

    /// `post` đẩy message vào hàng đợi gửi của phiên hiện tại.
    public func sessionStarted(flavor: ServerFlavor, post: @escaping @MainActor ([ClientMessage]) -> Void) {
        self.flavor = flavor
        self.post = post
        detector.reset()
        pendingTokens.removeAll()
        latestStandardText = nil
        standardPushAcceptedUntil = nil
        syncedChangeCount = nil // clipboard thiết bị chưa từng được đồng bộ trong phiên này: ⌘V đầu tiên sẽ gửi nó
    }

    public func sessionEnded() {
        post = nil
        detector.reset()
        pendingTokens.removeAll()
        pullTask?.cancel()
    }

    // MARK: - Thiết bị → Mac

    /// Lọc một lô message phím sắp gửi: ở chế độ tự động, chèn clipboard của thiết bị **trước** phím `v` của ⌘V
    /// (cùng hàng đợi nên tới Mac đúng thứ tự), và hẹn lấy clipboard Mac về sau ⌘C hay ⌘X.
    public func prepareOutgoing(_ messages: [ClientMessage]) -> [ClientMessage] {
        guard mode == .shared else { return messages }
        var result = messages
        // Duyệt từ cuối để các lần chèn không làm lệch chỉ số của những kết quả còn lại.
        for match in detector.observe(messages).reversed() {
            switch match.intent {
            case .paste:
                if let push = pendingPush() { result.insert(contentsOf: push, at: match.index) }
            case .copy:
                scheduleMacClipboardPull()
            }
        }
        return result
    }

    /// Nút Dán của hệ thống đã đọc clipboard thiết bị mà không cần hỏi quyền, và đưa chuỗi vào đây.
    public func send(text: String) {
        guard !text.isEmpty else { return showNotice("Clipboard của thiết bị đang trống.") }
        guard let messages = messages(forPushing: text) else { return }
        syncedChangeCount = pasteboard.changeCount
        post?(messages)
        showNotice("Đã gửi \(text.count) ký tự tới Mac.")
    }

    /// Message gửi clipboard thiết bị lên Mac nếu cần. `nil` nếu clipboard không có chữ hay chưa đổi từ lần đồng bộ trước.
    private func pendingPush() -> [ClientMessage]? {
        guard post != nil, pasteboard.hasStrings else { return nil } // `hasStrings` không hỏi quyền
        let count = pasteboard.changeCount
        guard count != syncedChangeCount else { return nil }
        guard let text = pasteboard.string, !text.isEmpty else { // chỉ đọc nội dung ở đây
            // `hasStrings` đúng mà đọc ra rỗng: người dùng đã chọn "Không cho phép dán" ở hộp thoại của iOS.
            showNotice("Không dán được: iOS đang chặn đọc clipboard. Bật Cài đặt › RemoteScreen › Dán từ ứng dụng khác.")
            return nil
        }
        guard let messages = messages(forPushing: text) else { return nil }
        syncedChangeCount = count
        showNotice("Đã gửi \(text.count) ký tự tới Mac.")
        return messages
    }

    private func messages(forPushing text: String) -> [ClientMessage]? {
        switch flavor {
        case .apple:
            do { return [.clipboardSend(try ClipboardTransfer(text: text))] } catch {
                showNotice("Clipboard quá lớn để gửi lên Mac.")
                return nil
            }
        case .standard:
            return [.clientCutText(text)]
        }
    }

    // MARK: - Mac → thiết bị

    /// Lấy clipboard Mac về thiết bị. Người dùng bấm nút, hoặc tự động sau ⌘C.
    public func requestFromMac() {
        switch flavor {
        case .apple:
            let token = UInt32.random(in: 1...UInt32.max)
            pendingTokens.insert(token)
            post?([.clipboardRequest(token: token)])
        case .standard:
            // Server chuẩn không cho hỏi. Nó tự đẩy khi Mac sao chép, và ta đã giữ lần gần nhất.
            if let text = latestStandardText {
                write(text)
            } else {
                showNotice("Chưa nhận được clipboard nào từ Mac. Máy này tự gửi khi bạn sao chép trên Mac.")
            }
        }
    }

    private func scheduleMacClipboardPull() {
        pullTask?.cancel()
        standardPushAcceptedUntil = ContinuousClock.now + Self.standardPushWindow
        let delay = copyDelay
        pullTask = Task { [weak self] in
            // Đợi Mac xử lý xong ⌘C và ghi clipboard.
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.requestFromMac()
        }
    }

    /// Câu trả lời của server Apple cho một `clipboardRequest`.
    public func receive(_ transfer: ClipboardTransfer) {
        // Chỉ nhận câu trả lời cho yêu cầu của mình: server không tự ý ghi vào clipboard thiết bị.
        guard pendingTokens.remove(transfer.token) != nil else { return }
        let payload: PasteboardPayload
        do { payload = try transfer.decodePayload() } catch {
            return showNotice("Không đọc được clipboard từ Mac.")
        }
        guard let text = payload.text, !text.isEmpty else {
            return showNotice("Clipboard của Mac đang trống hoặc không phải văn bản.")
        }
        if Self.isSensitive(payload) {
            pasteboard.writeSensitive(text, expiresAfter: Self.sensitiveLifetime)
            syncedChangeCount = pasteboard.changeCount
            showNotice("Đã chép nội dung nhạy cảm từ Mac (chỉ trên máy này, tự xóa sau \(Int(Self.sensitiveLifetime)) giây).")
            return
        }
        write(text)
    }

    /// Đánh dấu của nspasteboard.org mà trình quản lý mật khẩu trên Mac gắn vào clipboard: không nên đồng bộ đi khắp nơi.
    static let sensitiveTypes: Set<String> = [
        "org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType", "org.nspasteboard.AutoGeneratedType",
    ]
    static let sensitiveLifetime: TimeInterval = 90

    static func isSensitive(_ payload: PasteboardPayload) -> Bool {
        payload.representations.contains { sensitiveTypes.contains($0.uti) }
    }

    /// Server báo clipboard quá lớn và đã bị bỏ qua (phiên vẫn chạy). Chỉ báo khi chính ta vừa xin.
    public func noteSkipped(bytes: Int) {
        let megabytes = Double(bytes) / 1_048_576
        showNotice("Clipboard của Mac quá lớn (\(megabytes.formatted(.number.precision(.fractionLength(1)))) MB) nên đã bỏ qua.")
    }

    /// `ServerCutText` của server chuẩn (Latin-1).
    ///
    /// Server tự đẩy, nên **không** ghi thẳng vào clipboard thiết bị: một server độc hại hay bị chiếm quyền có thể gài lệnh hay
    /// đường dẫn rồi chờ người dùng dán ở nơi khác, và Universal Clipboard còn đưa nó sang các thiết bị khác. Văn bản chỉ được
    /// ghi khi người dùng vừa chủ động sao chép trên Mac (chế độ tự động) hoặc bấm nút Lấy; còn lại được giữ lại trong bộ nhớ.
    public func receive(cutText text: String) {
        latestStandardText = text
        guard mode == .shared, !text.isEmpty, let until = standardPushAcceptedUntil, ContinuousClock.now <= until else { return }
        standardPushAcceptedUntil = nil
        write(text)
    }

    private func write(_ text: String) {
        pasteboard.string = text // ghi không hỏi quyền
        syncedChangeCount = pasteboard.changeCount // chính ta vừa ghi: lần ⌘V sau không cần gửi ngược lên Mac
        showNotice("Đã chép \(text.count) ký tự từ Mac.")
    }

    // MARK: - Thông báo

    private func showNotice(_ text: String) {
        notice = text
        noticeTask?.cancel()
        let duration = noticeDuration
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }
}
