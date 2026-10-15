import Foundation
import InputKit
import RFBKit
import Localization
import Testing
@testable import SessionKit

/// Fake pasteboard. `stringReads` counts how many times the content is READ: each such read on iOS may show the allow-paste prompt.
@MainActor
private final class FakePasteboard: PasteboardAccess {
    private(set) var stringReads = 0
    private(set) var stringWrites = 0
    var changeCount = 1
    /// Simulates the user tapping "Don't Allow Paste": `hasStrings` stays true but reading the content gives `nil`.
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

    /// The user copies something in another app on the device.
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

/// Waits up to `seconds` seconds for a condition to become true (polling every 10 ms). Used instead of a fixed sleep, because when many tests
/// run in parallel on the main actor real timing stretches.
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
@Suite("ClipboardBridge: send to the Mac (⌘V)")
struct PushTests {
    init() { Localization.forcedLanguage = "en" }

    @Test func pasteShortcutPutsTheDeviceClipboardBeforeTheKey() throws {
        let harness = Harness()
        harness.pasteboard.userCopies("Xin chào đệ")
        let keys: [ClientMessage] = [down(command), down(0x76), up(0x76), up(command)]
        let result = harness.bridge.prepareOutgoing(keys)

        #expect(result.count == 5)
        #expect(result[0] == down(command))
        guard case .clipboardSend(let transfer) = result[1] else { Issue.record("the clipboard must be inserted right before the v key"); return }
        #expect(try transfer.decodePayload().text == "Xin chào đệ")
        #expect(Array(result[2...]) == [down(0x76), up(0x76), up(command)], "keys keep their order")
    }

    @Test func unchangedClipboardIsNotSentAgain() {
        let harness = Harness()
        harness.pasteboard.userCopies("a")
        let keys: [ClientMessage] = [down(command), down(0x76), up(0x76), up(command)]
        #expect(harness.bridge.prepareOutgoing(keys).count == 5)
        #expect(harness.bridge.prepareOutgoing(keys).count == 4, "second ⌘V: unchanged, so not sent again")
        harness.pasteboard.userCopies("b")
        #expect(harness.bridge.prepareOutgoing(keys).count == 5, "changed, so it is sent")
    }

    /// Reading the clipboard content can show the allow-paste prompt: read only when it will really be sent.
    @Test func neverReadsTheContentWhenThereIsNothingToSend() {
        let harness = Harness()
        let keys: [ClientMessage] = [down(command), down(0x76), up(0x76), up(command)]
        _ = harness.bridge.prepareOutgoing(keys) // clipboard empty
        #expect(harness.pasteboard.stringReads == 0)

        harness.pasteboard.userCopies("x")
        _ = harness.bridge.prepareOutgoing(keys)
        #expect(harness.pasteboard.stringReads == 1)
        _ = harness.bridge.prepareOutgoing(keys) // unchanged
        #expect(harness.pasteboard.stringReads == 1, "no re-read when changeCount is unchanged")
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
        _ = harness.bridge.prepareOutgoing([down(command)]) // ⌘ tapped on the accessory key bar
        let result = harness.bridge.prepareOutgoing([down(0x76), up(0x76), up(command)])
        #expect(result.count == 4)
        if case .clipboardSend = result[0] {} else { Issue.record("the clipboard must come before the v key") }
    }

    @Test func standardServerGetsClientCutText() {
        let harness = Harness(flavor: .standard)
        harness.pasteboard.userCopies("hello")
        let result = harness.bridge.prepareOutgoing([down(command), down(0x76)])
        #expect(result == [down(command), .clientCutText("hello"), down(0x76)])
    }

    @Test func pasteButtonSendsTheGivenTextAndMarksItSynced() throws {
        let harness = Harness()
        harness.pasteboard.userCopies("from the Paste button")
        harness.bridge.send(text: "from the Paste button")
        guard case .clipboardSend(let transfer) = try #require(harness.postedFlat.first) else { Issue.record("sai message"); return }
        #expect(try transfer.decodePayload().text == "from the Paste button")
        // Already synced: a ⌘V right after does not send again.
        #expect(harness.bridge.prepareOutgoing([down(command), down(0x76)]).count == 2)
    }

    @Test func emptyTextFromThePasteButtonIsAnError() {
        let harness = Harness()
        harness.bridge.send(text: "")
        #expect(harness.postedFlat.isEmpty)
        #expect(harness.bridge.notice != nil)
    }

    /// The user declined iOS's "allow paste" prompt: it must say clearly why ⌘V pasted nothing, and let the keys continue.
    @Test func deniedPasteExplainsItselfAndLetsTheKeysThrough() {
        let harness = Harness()
        harness.pasteboard.userCopies("blocked")
        harness.pasteboard.denyReads = true
        let keys: [ClientMessage] = [down(command), down(0x76), up(0x76)]
        #expect(harness.bridge.prepareOutgoing(keys) == keys)
        #expect(harness.bridge.notice?.contains("Paste from Other Apps") == true)
        // Not marked as synced: if the user changes their mind later, it can still be sent.
        harness.pasteboard.denyReads = false
        #expect(harness.bridge.prepareOutgoing(keys).count == 4)
    }

    @Test func tooLargeClipboardIsRefusedWithANotice() {
        let harness = Harness()
        harness.pasteboard.userCopies(String(repeating: "x", count: ClipboardTransfer.maxUncompressed + 1))
        let keys: [ClientMessage] = [down(command), down(0x76)]
        #expect(harness.bridge.prepareOutgoing(keys) == keys, "nothing inserted, keys continue")
        #expect(harness.bridge.notice?.contains("too large") == true)
    }
}

@MainActor
@Suite("ClipboardBridge: fetch from the Mac (⌘C)")
struct PullTests {
    init() { Localization.forcedLanguage = "en" }

    private func pendingToken(_ harness: Harness) -> UInt32? {
        for message in harness.postedFlat { if case .clipboardRequest(let token) = message { return token } }
        return nil
    }

    @Test func copyShortcutAsksTheMacAfterADelay() async throws {
        let harness = Harness()
        let keys: [ClientMessage] = [down(command), down(0x63), up(0x63), up(command)]
        #expect(harness.bridge.prepareOutgoing(keys) == keys, "⌘C does not change the keys")
        #expect(harness.postedFlat.isEmpty, "does not ask immediately: the Mac needs time to write its clipboard")
        #expect(await eventually { pendingToken(harness) != nil }, "must ask after the delay")
    }

    @Test func aSecondCopyBeforeTheDelayCoalescesIntoOneRequest() async throws {
        let harness = Harness(copyDelay: .milliseconds(60))
        let keys: [ClientMessage] = [down(command), down(0x63), up(0x63)]
        _ = harness.bridge.prepareOutgoing(keys)
        _ = harness.bridge.prepareOutgoing([down(0x63), up(0x63)])
        #expect(await eventually { pendingToken(harness) != nil })
        try await Task.sleep(for: .milliseconds(200)) // leave time for a second request (if there were a bug) to show up
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
        #expect(harness.bridge.notice?.contains("Copied") == true)
    }

    /// The server must not write to the device clipboard on its own: only answers to our own requests are accepted.
    @Test func unsolicitedOrReplayedRepliesAreIgnored() throws {
        let harness = Harness()
        harness.bridge.receive(try appleReply(token: 0xDEAD_BEEF, text: "unsolicited"))
        #expect(harness.pasteboard.stringWrites == 0)

        harness.bridge.requestFromMac()
        let token = try #require(pendingToken(harness))
        harness.bridge.receive(try appleReply(token: token, text: "once"))
        harness.bridge.receive(try appleReply(token: token, text: "repeated"))
        #expect(harness.pasteboard.stringWrites == 1, "each request may be answered only once")
        #expect(harness.pasteboard.string == "once")
    }

    @Test func whatWeJustWroteIsNotSentBackOnTheNextPaste() throws {
        let harness = Harness()
        harness.bridge.requestFromMac()
        harness.bridge.receive(try appleReply(token: try #require(pendingToken(harness)), text: "from Mac"))
        let keys: [ClientMessage] = [down(command), down(0x76)]
        #expect(harness.bridge.prepareOutgoing(keys) == keys, "the device clipboard is exactly what was just fetched from the Mac")
        #expect(harness.pasteboard.stringReads == 0, "no need to read the content because changeCount matches our own write")
    }

    @Test func corruptReplyShowsANoticeAndWritesNothing() throws {
        let harness = Harness()
        harness.bridge.requestFromMac()
        let token = try #require(pendingToken(harness))
        harness.bridge.receive(ClipboardTransfer(token: token, uncompressedSize: 10, compressed: Data(repeating: 0x55, count: 8)))
        #expect(harness.pasteboard.stringWrites == 0)
        #expect(harness.bridge.notice?.contains("Couldn't read") == true)
    }

    @Test func nonTextReplyShowsANoticeAndWritesNothing() throws {
        let harness = Harness()
        harness.bridge.requestFromMac()
        let token = try #require(pendingToken(harness))
        // The clipboard has only a PNG image, no text representation.
        let payload = PasteboardPayload(representations: [PasteboardRepresentation(uti: "public.png", data: Data([1, 2, 3]))])
        let raw = payload.serialized()
        let transfer = ClipboardTransfer(token: token, uncompressedSize: UInt32(raw.count), compressed: try ClipboardZlibForTests.deflate(raw))
        harness.bridge.receive(transfer)
        #expect(harness.pasteboard.stringWrites == 0)
        #expect(harness.bridge.notice?.contains("is not text") == true)
    }

    @Test func standardServerWithNothingReceivedExplainsInsteadOfAsking() {
        let harness = Harness(flavor: .standard)
        harness.bridge.requestFromMac()
        #expect(harness.postedFlat.isEmpty, "a standard server has no clipboard request message")
        #expect(harness.bridge.notice != nil)
    }

    @Test func standardServerPushRightAfterTheUsersCopyIsWritten() {
        let harness = Harness(flavor: .standard)
        _ = harness.bridge.prepareOutgoing([down(command), down(0x63), up(0x63), up(command)]) // ⌘C on the remote Mac
        harness.bridge.receive(cutText: "just copied")
        #expect(harness.pasteboard.string == "just copied")
    }

    @Test func standardServerPushesAreNeverWrittenUnlessTheUserJustCopied() {
        let shared = Harness(flavor: .standard)
        shared.bridge.receive(cutText: "arrived on its own")
        #expect(shared.pasteboard.stringWrites == 0, "a server push must not be written to the device clipboard")
        shared.bridge.requestFromMac()
        #expect(shared.pasteboard.string == "arrived on its own", "but the kept copy is fetched when the user taps")

        let manual = Harness(mode: .manual, flavor: .standard)
        manual.bridge.receive(cutText: "waiting for tap")
        #expect(manual.pasteboard.stringWrites == 0)
        manual.bridge.requestFromMac()
        #expect(manual.pasteboard.string == "waiting for tap", "the Get button writes the kept copy")
    }
}

@MainActor
@Suite("ClipboardBridge: mode and notices")
struct ModeAndNoticeTests {
    init() { Localization.forcedLanguage = "en" }

    @Test func defaultsToSharedAndPersistsTheChoice() {
        let defaults = UserDefaults(suiteName: "ClipboardBridgeMode-\(UUID().uuidString)")!
        let first = ClipboardBridge(pasteboard: FakePasteboard(), defaults: defaults)
        #expect(first.mode == .shared)
        first.mode = .manual
        #expect(ClipboardBridge(pasteboard: FakePasteboard(), defaults: defaults).mode == .manual)
    }

    @Test func garbageInDefaultsFallsBackToTheDefault() {
        let defaults = UserDefaults(suiteName: "ClipboardBridgeBad-\(UUID().uuidString)")!
        defaults.set("no-such-mode", forKey: ClipboardBridge.modeKey)
        #expect(ClipboardBridge(pasteboard: FakePasteboard(), defaults: defaults).mode == .shared)
    }

    @Test func noticeClearsItself() async throws {
        let harness = Harness(noticeDuration: .milliseconds(40))
        harness.bridge.send(text: "x")
        #expect(harness.bridge.notice != nil)
        #expect(await eventually { harness.bridge.notice == nil }, "the notice must disappear on its own")
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
        harness.bridge.receive(try appleReply(token: token, text: "late"))
        #expect(harness.pasteboard.stringWrites == 0)
        harness.bridge.send(text: "no session")
        #expect(harness.posted.count == 1, "only the earlier request remains")
    }
}

@MainActor
@Suite("ClipboardBridge: sensitive content and oversized clipboard")
struct SensitiveClipboardTests {
    init() { Localization.forcedLanguage = "en" }

    private func pendingToken(_ harness: Harness) -> UInt32? {
        for message in harness.postedFlat { if case .clipboardRequest(let token) = message { return token } }
        return nil
    }

    private func reply(_ harness: Harness, token: UInt32, representations: [PasteboardRepresentation]) throws -> ClipboardTransfer {
        let raw = PasteboardPayload(representations: representations).serialized()
        return ClipboardTransfer(token: token, uncompressedSize: UInt32(raw.count), compressed: try ClipboardZlibForTests.deflate(raw))
    }

    /// A password copied from a password manager on the Mac carries the Concealed marker: it must not become an ordinary clipboard (synced via
    /// Universal Clipboard to every device, never expiring).
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
        #expect(harness.pasteboard.stringWrites == 0, "not written the ordinary way")
    }

    @Test func ordinaryTextStillUsesTheNormalClipboard() throws {
        let harness = Harness()
        harness.bridge.requestFromMac()
        let token = try #require(pendingToken(harness))
        harness.bridge.receive(try reply(harness, token: token, representations: [
            PasteboardRepresentation(uti: "public.utf8-plain-text", data: Data("ordinary".utf8)),
        ]))
        #expect(harness.pasteboard.sensitiveWrites.isEmpty)
        #expect(harness.pasteboard.stringWrites == 1)
    }

    @Test func skippedClipboardExplainsInMegabytes() {
        let harness = Harness()
        harness.bridge.noteSkipped(bytes: 20 * 1_048_576)
        #expect(harness.bridge.notice?.contains("too large") == true)
        #expect(harness.bridge.notice?.contains("20") == true)
    }
}
