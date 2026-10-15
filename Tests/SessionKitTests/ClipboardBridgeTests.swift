import Foundation
import InputKit
import RFBKit
import Testing
@testable import SessionKit

/// Bảng clipboard giả. `stringReads` đếm số lần ĐỌC nội dung: mỗi lần như vậy trên iOS có thể hiện hộp thoại cho phép dán.
@MainActor
private final class FakePasteboard: PasteboardAccess {
    private(set) var stringReads = 0
    private(set) var stringWrites = 0
    var changeCount = 1
    /// Giả lập người dùng bấm "Không cho phép dán": `hasStrings` vẫn đúng nhưng đọc nội dung ra `nil`.
    var denyReads = false
    private var storage: String?

    var hasStrings: Bool { storage != nil }
    private(set) var sensitiveWrites: [(String, TimeInterval)] = []

    func writeSensitive(_ text: String, expiresAfter seconds: TimeInterval) {
        sensitiveWrites.append((text, seconds))
        storage = text
        changeCount += 1
    }

    var string: String? {
        get { stringReads += 1; return denyReads ? nil : storage }
        set { stringWrites += 1; storage = newValue; changeCount += 1 }
    }

    /// Người dùng sao chép thứ gì đó ở app khác trên thiết bị.
    func userCopies(_ text: String) {
        storage = text
        changeCount += 1
    }
}

@MainActor
private final class Harness {
    let pasteboard = FakePasteboard()
    let defaults = UserDefaults(suiteName: "ClipboardBridgeTests-\(UUID().uuidString)")!
    let bridge: ClipboardBridge
    private(set) var posted: [[ClientMessage]] = []

    init(mode: ClipboardBridge.Mode = .shared, flavor: ServerFlavor = .apple, copyDelay: Duration = .milliseconds(10), noticeDuration: Duration = .seconds(60)) {
        bridge = ClipboardBridge(pasteboard: pasteboard, defaults: defaults, copyDelay: copyDelay, noticeDuration: noticeDuration)
        bridge.mode = mode
        bridge.sessionStarted(flavor: flavor) { [unowned self] in posted.append($0) }
    }

    var postedFlat: [ClientMessage] { posted.flatMap { $0 } }
}

/// Chờ một điều kiện đúng tối đa `seconds` giây (thăm dò mỗi 10 ms). Dùng thay cho một lần ngủ cố định, vì khi nhiều test chạy
/// song song trên main actor thì thời gian thực tế co giãn.
@MainActor
private func eventually(seconds: Double = 5, _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(seconds)
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

private let command = KeysymMapper.commandLeft
private func down(_ keysym: UInt32) -> ClientMessage { .keyEvent(isDown: true, keysym: keysym) }
private func up(_ keysym: UInt32) -> ClientMessage { .keyEvent(isDown: false, keysym: keysym) }

private func appleReply(token: UInt32, text: String) throws -> ClipboardTransfer {
    var transfer = try ClipboardTransfer(text: text)
    transfer.token = token
    return transfer
}

@MainActor
@Suite("ClipboardBridge: gửi lên Mac (⌘V)")
struct PushTests {
    @Test func pasteShortcutPutsTheDeviceClipboardBeforeTheKey() throws {
        let harness = Harness()
        harness.pasteboard.userCopies("Xin chào đệ")
        let keys: [ClientMessage] = [down(command), down(0x76), up(0x76), up(command)]
        let result = harness.bridge.prepareOutgoing(keys)

        #expect(result.count == 5)
        #expect(result[0] == down(command))
        guard case .clipboardSend(let transfer) = result[1] else { Issue.record("phải chèn clipboard ngay trước phím v"); return }
        #expect(try transfer.decodePayload().text == "Xin chào đệ")
        #expect(Array(result[2...]) == [down(0x76), up(0x76), up(command)], "các phím giữ nguyên thứ tự")
    }

    @Test func unchangedClipboardIsNotSentAgain() {
        let harness = Harness()
        harness.pasteboard.userCopies("a")
        let keys: [ClientMessage] = [down(command), down(0x76), up(0x76), up(command)]
        #expect(harness.bridge.prepareOutgoing(keys).count == 5)
        #expect(harness.bridge.prepareOutgoing(keys).count == 4, "lần ⌘V thứ hai: chưa đổi nên không gửi lại")
        harness.pasteboard.userCopies("b")
        #expect(harness.bridge.prepareOutgoing(keys).count == 5, "đã đổi thì gửi")
    }

    /// Đọc nội dung clipboard có thể hiện hộp thoại cho phép dán: chỉ đọc khi thật sự sẽ gửi.
    @Test func neverReadsTheContentWhenThereIsNothingToSend() {
        let harness = Harness()
        let keys: [ClientMessage] = [down(command), down(0x76), up(0x76), up(command)]
        _ = harness.bridge.prepareOutgoing(keys) // clipboard trống
        #expect(harness.pasteboard.stringReads == 0)

        harness.pasteboard.userCopies("x")
        _ = harness.bridge.prepareOutgoing(keys)
        #expect(harness.pasteboard.stringReads == 1)
        _ = harness.bridge.prepareOutgoing(keys) // chưa đổi
        #expect(harness.pasteboard.stringReads == 1, "không đọc lại khi changeCount không đổi")
    }

    @Test func manualModeNeverInterceptsAnything() {
        let harness = Harness(mode: .manual)
        harness.pasteboard.userCopies("x")
        let keys: [ClientMessage] = [down(command), down(0x76), up(0x76), up(command)]
        #expect(harness.bridge.prepareOutgoing(keys) == keys)
        #expect(harness.pasteboard.stringReads == 0)
    }

    @Test func plainVIsNotAPasteShortcut() {
        let harness = Harness()
        harness.pasteboard.userCopies("x")
        let keys: [ClientMessage] = [down(0x76), up(0x76)]
        #expect(harness.bridge.prepareOutgoing(keys) == keys)
        #expect(harness.pasteboard.stringReads == 0)
    }

    @Test func stickyCommandOnTheKeyBarWorksAcrossBatches() {
        let harness = Harness()
        harness.pasteboard.userCopies("x")
        _ = harness.bridge.prepareOutgoing([down(command)]) // chạm ⌘ trên thanh phím phụ
        let result = harness.bridge.prepareOutgoing([down(0x76), up(0x76), up(command)])
        #expect(result.count == 4)
        if case .clipboardSend = result[0] {} else { Issue.record("clipboard phải đứng trước phím v") }
    }

    @Test func standardServerGetsClientCutText() {
        let harness = Harness(flavor: .standard)
        harness.pasteboard.userCopies("hello")
        let result = harness.bridge.prepareOutgoing([down(command), down(0x76)])
        #expect(result == [down(command), .clientCutText("hello"), down(0x76)])
    }

    @Test func pasteButtonSendsTheGivenTextAndMarksItSynced() throws {
        let harness = Harness()
        harness.pasteboard.userCopies("từ nút Dán")
        harness.bridge.send(text: "từ nút Dán")
        guard case .clipboardSend(let transfer) = try #require(harness.postedFlat.first) else { Issue.record("sai message"); return }
        #expect(try transfer.decodePayload().text == "từ nút Dán")
        // Đã đồng bộ: ⌘V ngay sau đó không gửi thêm lần nữa.
        #expect(harness.bridge.prepareOutgoing([down(command), down(0x76)]).count == 2)
    }

    @Test func emptyTextFromThePasteButtonIsAnError() {
        let harness = Harness()
        harness.bridge.send(text: "")
        #expect(harness.postedFlat.isEmpty)
        #expect(harness.bridge.notice != nil)
    }

    /// Hộp thoại "cho phép dán" của iOS mà người dùng từ chối: phải nói rõ vì sao ⌘V không dán gì, và để phím vẫn đi tiếp.
    @Test func deniedPasteExplainsItselfAndLetsTheKeysThrough() {
        let harness = Harness()
        harness.pasteboard.userCopies("bị chặn")
        harness.pasteboard.denyReads = true
        let keys: [ClientMessage] = [down(command), down(0x76), up(0x76)]
        #expect(harness.bridge.prepareOutgoing(keys) == keys)
        #expect(harness.bridge.notice?.contains("Dán từ ứng dụng khác") == true)
        // Không đánh dấu là đã đồng bộ: lần sau người dùng đổi ý thì vẫn gửi được.
        harness.pasteboard.denyReads = false
        #expect(harness.bridge.prepareOutgoing(keys).count == 4)
    }

    @Test func tooLargeClipboardIsRefusedWithANotice() {
        let harness = Harness()
        harness.pasteboard.userCopies(String(repeating: "x", count: ClipboardTransfer.maxUncompressed + 1))
        let keys: [ClientMessage] = [down(command), down(0x76)]
        #expect(harness.bridge.prepareOutgoing(keys) == keys, "không chèn gì, phím vẫn đi tiếp")
        #expect(harness.bridge.notice?.contains("quá lớn") == true)
    }
}

@MainActor
@Suite("ClipboardBridge: lấy từ Mac (⌘C)")
struct PullTests {
    private func pendingToken(_ harness: Harness) -> UInt32? {
        for message in harness.postedFlat { if case .clipboardRequest(let token) = message { return token } }
        return nil
    }

    @Test func copyShortcutAsksTheMacAfterADelay() async throws {
        let harness = Harness()
        let keys: [ClientMessage] = [down(command), down(0x63), up(0x63), up(command)]
        #expect(harness.bridge.prepareOutgoing(keys) == keys, "⌘C không đổi các phím")
        #expect(harness.postedFlat.isEmpty, "chưa hỏi ngay: Mac cần thời gian ghi clipboard")
        #expect(await eventually { pendingToken(harness) != nil }, "phải hỏi sau độ trễ")
    }

    @Test func aSecondCopyBeforeTheDelayCoalescesIntoOneRequest() async throws {
        let harness = Harness(copyDelay: .milliseconds(60))
        let keys: [ClientMessage] = [down(command), down(0x63), up(0x63)]
        _ = harness.bridge.prepareOutgoing(keys)
        _ = harness.bridge.prepareOutgoing([down(0x63), up(0x63)])
        #expect(await eventually { pendingToken(harness) != nil })
        try await Task.sleep(for: .milliseconds(200)) // chừa thời gian cho một yêu cầu thứ hai (nếu có lỗi) kịp xuất hiện
        #expect(harness.postedFlat.filter { if case .clipboardRequest = $0 { true } else { false } }.count == 1)
    }

    @Test func manualModeDoesNotPullAfterCopy() async throws {
        let harness = Harness(mode: .manual)
        _ = harness.bridge.prepareOutgoing([down(command), down(0x63)])
        try await Task.sleep(for: .milliseconds(100))
        #expect(harness.postedFlat.isEmpty)
    }

    @Test func matchingReplyIsWrittenToTheDeviceClipboardWithVietnameseIntact() throws {
        let harness = Harness()
        harness.bridge.requestFromMac()
        let token = try #require(pendingToken(harness))
        harness.bridge.receive(try appleReply(token: token, text: "Việt Nam đệ ố ữ 🙂"))
        #expect(harness.pasteboard.string == "Việt Nam đệ ố ữ 🙂")
        #expect(harness.bridge.notice?.contains("Đã chép") == true)
    }

    /// Server không được tự ý ghi vào clipboard thiết bị: chỉ nhận câu trả lời cho yêu cầu của mình.
    @Test func unsolicitedOrReplayedRepliesAreIgnored() throws {
        let harness = Harness()
        harness.bridge.receive(try appleReply(token: 0xDEAD_BEEF, text: "tự ý"))
        #expect(harness.pasteboard.stringWrites == 0)

        harness.bridge.requestFromMac()
        let token = try #require(pendingToken(harness))
        harness.bridge.receive(try appleReply(token: token, text: "một lần"))
        harness.bridge.receive(try appleReply(token: token, text: "lặp lại"))
        #expect(harness.pasteboard.stringWrites == 1, "mỗi yêu cầu chỉ được trả lời một lần")
        #expect(harness.pasteboard.string == "một lần")
    }

    @Test func whatWeJustWroteIsNotSentBackOnTheNextPaste() throws {
        let harness = Harness()
        harness.bridge.requestFromMac()
        harness.bridge.receive(try appleReply(token: try #require(pendingToken(harness)), text: "từ Mac"))
        let keys: [ClientMessage] = [down(command), down(0x76)]
        #expect(harness.bridge.prepareOutgoing(keys) == keys, "clipboard thiết bị chính là thứ vừa lấy từ Mac")
        #expect(harness.pasteboard.stringReads == 0, "không cần đọc nội dung vì changeCount khớp lần ghi của ta")
    }

    @Test func corruptReplyShowsANoticeAndWritesNothing() throws {
        let harness = Harness()
        harness.bridge.requestFromMac()
        let token = try #require(pendingToken(harness))
        harness.bridge.receive(ClipboardTransfer(token: token, uncompressedSize: 10, compressed: Data(repeating: 0x55, count: 8)))
        #expect(harness.pasteboard.stringWrites == 0)
        #expect(harness.bridge.notice?.contains("Không đọc được") == true)
    }

    @Test func nonTextReplyShowsANoticeAndWritesNothing() throws {
        let harness = Harness()
        harness.bridge.requestFromMac()
        let token = try #require(pendingToken(harness))
        // Clipboard chỉ có ảnh PNG, không có biểu diễn văn bản nào.
        let payload = PasteboardPayload(representations: [PasteboardRepresentation(uti: "public.png", data: Data([1, 2, 3]))])
        let raw = payload.serialized()
        let transfer = ClipboardTransfer(token: token, uncompressedSize: UInt32(raw.count), compressed: try ClipboardZlibForTests.deflate(raw))
        harness.bridge.receive(transfer)
        #expect(harness.pasteboard.stringWrites == 0)
        #expect(harness.bridge.notice?.contains("không phải văn bản") == true)
    }

    @Test func standardServerWithNothingReceivedExplainsInsteadOfAsking() {
        let harness = Harness(flavor: .standard)
        harness.bridge.requestFromMac()
        #expect(harness.postedFlat.isEmpty, "server chuẩn không có message hỏi clipboard")
        #expect(harness.bridge.notice != nil)
    }

    @Test func standardServerPushRightAfterTheUsersCopyIsWritten() {
        let harness = Harness(flavor: .standard)
        _ = harness.bridge.prepareOutgoing([down(command), down(0x63), up(0x63), up(command)]) // ⌘C trên Mac từ xa
        harness.bridge.receive(cutText: "vừa sao chép")
        #expect(harness.pasteboard.string == "vừa sao chép")
    }

    @Test func standardServerPushesAreNeverWrittenUnlessTheUserJustCopied() {
        let shared = Harness(flavor: .standard)
        shared.bridge.receive(cutText: "tự đến")
        #expect(shared.pasteboard.stringWrites == 0, "server tự đẩy không được ghi vào clipboard thiết bị")
        shared.bridge.requestFromMac()
        #expect(shared.pasteboard.string == "tự đến", "nhưng bản đã giữ được lấy khi người dùng bấm")

        let manual = Harness(mode: .manual, flavor: .standard)
        manual.bridge.receive(cutText: "chờ bấm")
        #expect(manual.pasteboard.stringWrites == 0)
        manual.bridge.requestFromMac()
        #expect(manual.pasteboard.string == "chờ bấm", "nút Lấy ghi bản đã giữ")
    }
}

@MainActor
@Suite("ClipboardBridge: chế độ và thông báo")
struct ModeAndNoticeTests {
    @Test func defaultsToSharedAndPersistsTheChoice() {
        let defaults = UserDefaults(suiteName: "ClipboardBridgeMode-\(UUID().uuidString)")!
        let first = ClipboardBridge(pasteboard: FakePasteboard(), defaults: defaults)
        #expect(first.mode == .shared)
        first.mode = .manual
        #expect(ClipboardBridge(pasteboard: FakePasteboard(), defaults: defaults).mode == .manual)
    }

    @Test func garbageInDefaultsFallsBackToTheDefault() {
        let defaults = UserDefaults(suiteName: "ClipboardBridgeBad-\(UUID().uuidString)")!
        defaults.set("không-có-chế-độ-này", forKey: ClipboardBridge.modeKey)
        #expect(ClipboardBridge(pasteboard: FakePasteboard(), defaults: defaults).mode == .shared)
    }

    @Test func noticeClearsItself() async throws {
        let harness = Harness(noticeDuration: .milliseconds(40))
        harness.bridge.send(text: "x")
        #expect(harness.bridge.notice != nil)
        #expect(await eventually { harness.bridge.notice == nil }, "thông báo phải tự biến mất")
    }

    @Test func aStuckCommandFromBeforeAModeSwitchDoesNotTrigger() {
        let harness = Harness(mode: .shared)
        harness.pasteboard.userCopies("x")
        _ = harness.bridge.prepareOutgoing([down(command)])
        harness.bridge.mode = .manual
        harness.bridge.mode = .shared
        let keys: [ClientMessage] = [down(0x76)]
        #expect(harness.bridge.prepareOutgoing(keys) == keys)
    }

    @Test func endingTheSessionStopsPostingAndForgetsPendingRequests() throws {
        let harness = Harness()
        harness.bridge.requestFromMac()
        let token = try #require({ () -> UInt32? in
            for message in harness.postedFlat { if case .clipboardRequest(let t) = message { return t } }
            return nil
        }())
        harness.bridge.sessionEnded()
        harness.bridge.receive(try appleReply(token: token, text: "muộn"))
        #expect(harness.pasteboard.stringWrites == 0)
        harness.bridge.send(text: "không có phiên")
        #expect(harness.posted.count == 1, "chỉ còn lần hỏi trước đó")
    }
}

@MainActor
@Suite("ClipboardBridge: nội dung nhạy cảm và clipboard quá lớn")
struct SensitiveClipboardTests {
    private func pendingToken(_ harness: Harness) -> UInt32? {
        for message in harness.postedFlat { if case .clipboardRequest(let token) = message { return token } }
        return nil
    }

    private func reply(_ harness: Harness, token: UInt32, representations: [PasteboardRepresentation]) throws -> ClipboardTransfer {
        let raw = PasteboardPayload(representations: representations).serialized()
        return ClipboardTransfer(token: token, uncompressedSize: UInt32(raw.count), compressed: try ClipboardZlibForTests.deflate(raw))
    }

    /// Mật khẩu chép từ trình quản lý mật khẩu trên Mac mang dấu Concealed: không được thành clipboard thường (đồng bộ qua
    /// Universal Clipboard sang mọi thiết bị, không hết hạn).
    @Test func concealedTextIsWrittenLocallyAndExpires() throws {
        let harness = Harness()
        harness.bridge.requestFromMac()
        let token = try #require(pendingToken(harness))
        let transfer = try reply(harness, token: token, representations: [
            PasteboardRepresentation(uti: "public.utf8-plain-text", data: Data("mật-khẩu-bí-mật".utf8)),
            PasteboardRepresentation(uti: "org.nspasteboard.ConcealedType", data: Data()),
        ])
        harness.bridge.receive(transfer)
        #expect(harness.pasteboard.sensitiveWrites.map(\.0) == ["mật-khẩu-bí-mật"])
        #expect(harness.pasteboard.sensitiveWrites.first?.1 == 90)
        #expect(harness.pasteboard.stringWrites == 0, "không ghi theo đường thường")
    }

    @Test func ordinaryTextStillUsesTheNormalClipboard() throws {
        let harness = Harness()
        harness.bridge.requestFromMac()
        let token = try #require(pendingToken(harness))
        harness.bridge.receive(try reply(harness, token: token, representations: [
            PasteboardRepresentation(uti: "public.utf8-plain-text", data: Data("bình thường".utf8)),
        ]))
        #expect(harness.pasteboard.sensitiveWrites.isEmpty)
        #expect(harness.pasteboard.stringWrites == 1)
    }

    @Test func skippedClipboardExplainsInMegabytes() {
        let harness = Harness()
        harness.bridge.noteSkipped(bytes: 20 * 1_048_576)
        #expect(harness.bridge.notice?.contains("quá lớn") == true)
        #expect(harness.bridge.notice?.contains("20") == true)
    }
}
