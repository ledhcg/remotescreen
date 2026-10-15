import Foundation
import InputKit
import Observation
import RFBKit

/// The device's pasteboard, separated from UIKit so it can be tested.
///
/// On iOS, **reading** content copied by another app shows the "allow paste" prompt, while reading `changeCount` and
/// `hasStrings` does not. Both `ClipboardBridge` and this protocol are designed to read the content only when it really must be sent.
@MainActor
public protocol PasteboardAccess: AnyObject {
    var changeCount: Int { get }
    var hasStrings: Bool { get }
    /// Reading can trigger iOS's allow-paste prompt. Writing does not.
    var string: String? { get set }
    /// Writes sensitive text (a password copied from a password manager on the Mac): local to this device (not via Universal Clipboard)
    /// and set to expire.
    func writeSensitive(_ text: String, expiresAfter seconds: TimeInterval)
}

extension PasteboardAccess {
    public func writeSensitive(_ text: String, expiresAfter seconds: TimeInterval) {
        string = text
    }
}

/// Synchronises the clipboard between the device and the Mac.
///
/// - Apple server: its own request/response protocol with UTF-8 (`ClipboardTransfer`). The Mac → device direction is always initiated by us.
/// - Standard RFB server: `ClientCutText` / `ServerCutText` (Latin-1). The server pushes its clipboard when it changes.
///
/// Two modes:
/// - **Manual**: only when the user taps a button (fetch from the Mac, or the Paste button to send to the Mac).
/// - **Automatic**: adds two shortcuts. After ⌘C or ⌘X on the remote Mac, the Mac clipboard is fetched to the device a moment later. ⌘V sends
///   the device clipboard to the Mac right before the `v` key, but only if it changed since the last sync.
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
            detector.reset() // a ⌘ remembered from the previous mode must not trigger a command in the new mode
        }
    }

    /// Short notice for the user, disappears on its own.
    public private(set) var notice: String?

    @ObservationIgnored private let pasteboard: any PasteboardAccess
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let copyDelay: Duration
    @ObservationIgnored private let noticeDuration: Duration
    @ObservationIgnored private var post: (@MainActor ([ClientMessage]) -> Void)?
    @ObservationIgnored private var flavor: ServerFlavor = .standard
    @ObservationIgnored private var detector = ClipboardShortcutDetector()
    @ObservationIgnored private var pendingTokens: Set<UInt32> = []
    /// The pasteboard's `changeCount` right after our most recent write or send. A different value means the user copied
    /// something new on the device, which must be sent to the Mac on paste.
    @ObservationIgnored private var syncedChangeCount: Int?
    /// The most recent text the Mac sent via the standard protocol (a standard server pushes on its own and cannot be asked).
    @ObservationIgnored private var latestStandardText: String?
    /// A standard server pushes its clipboard at any time without the user doing anything. Only within a short window after the user
    /// copied on the Mac (⌘C/⌘X) do we treat an incoming push as something they want; outside that window it is only kept.
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

    // MARK: - Session lifecycle

    /// `post` pushes messages onto the current session's send queue.
    public func sessionStarted(flavor: ServerFlavor, post: @escaping @MainActor ([ClientMessage]) -> Void) {
        self.flavor = flavor
        self.post = post
        detector.reset()
        pendingTokens.removeAll()
        latestStandardText = nil
        standardPushAcceptedUntil = nil
        syncedChangeCount = nil // the device clipboard has never been synced in this session: the first ⌘V will send it
    }

    public func sessionEnded() {
        post = nil
        detector.reset()
        pendingTokens.removeAll()
        pullTask?.cancel()
    }

    // MARK: - Device → Mac

    /// Filters a batch of key messages about to be sent: in automatic mode, inserts the device clipboard **before** the `v` key of ⌘V
    /// (same queue, so it reaches the Mac in order), and schedules fetching the Mac clipboard after ⌘C or ⌘X.
    public func prepareOutgoing(_ messages: [ClientMessage]) -> [ClientMessage] {
        guard mode == .shared else { return messages }
        var result = messages
        // Walk from the end so insertions do not shift the indices of the remaining matches.
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

    /// The system Paste button read the device clipboard without needing permission, and hands the string in here.
    public func send(text: String) {
        guard !text.isEmpty else { return showNotice(tr("The device clipboard is empty.")) }
        guard let messages = messages(forPushing: text) else { return }
        syncedChangeCount = pasteboard.changeCount
        post?(messages)
        showNotice(tr("Sent %lld characters to the Mac.", text.count))
    }

    /// Messages that send the device clipboard to the Mac if needed. `nil` if the clipboard has no text or has not changed since the last sync.
    private func pendingPush() -> [ClientMessage]? {
        guard post != nil, pasteboard.hasStrings else { return nil } // `hasStrings` does not ask for permission
        let count = pasteboard.changeCount
        guard count != syncedChangeCount else { return nil }
        guard let text = pasteboard.string, !text.isEmpty else { // the content is read only here
            // `hasStrings` is true but the read came back empty: the user chose "Don't Allow Paste" in iOS's prompt.
            showNotice(tr("Couldn't paste: iOS is blocking clipboard access. Turn on Settings › Screon › Paste from Other Apps."))
            return nil
        }
        guard let messages = messages(forPushing: text) else { return nil }
        syncedChangeCount = count
        showNotice(tr("Sent %lld characters to the Mac.", text.count))
        return messages
    }

    private func messages(forPushing text: String) -> [ClientMessage]? {
        switch flavor {
        case .apple:
            do { return [.clipboardSend(try ClipboardTransfer(text: text))] } catch {
                showNotice(tr("The clipboard is too large to send to the Mac."))
                return nil
            }
        case .standard:
            return [.clientCutText(text)]
        }
    }

    // MARK: - Mac → device

    /// Fetches the Mac clipboard to the device. Triggered by a button tap, or automatically after ⌘C.
    public func requestFromMac() {
        switch flavor {
        case .apple:
            let token = UInt32.random(in: 1...UInt32.max)
            pendingTokens.insert(token)
            post?([.clipboardRequest(token: token)])
        case .standard:
            // A standard server cannot be asked. It pushes when the Mac copies, and we kept the latest one.
            if let text = latestStandardText {
                write(text)
            } else {
                showNotice(tr("No clipboard received from the Mac yet. This computer sends it automatically when you copy on the Mac."))
            }
        }
    }

    private func scheduleMacClipboardPull() {
        pullTask?.cancel()
        standardPushAcceptedUntil = ContinuousClock.now + Self.standardPushWindow
        let delay = copyDelay
        pullTask = Task { [weak self] in
            // Wait for the Mac to finish handling ⌘C and write its clipboard.
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.requestFromMac()
        }
    }

    /// Apple server's answer to a `clipboardRequest`.
    public func receive(_ transfer: ClipboardTransfer) {
        // Accept only answers to our own requests: the server must not write to the device clipboard on its own.
        guard pendingTokens.remove(transfer.token) != nil else { return }
        let payload: PasteboardPayload
        do { payload = try transfer.decodePayload() } catch {
            return showNotice(tr("Couldn't read the clipboard from the Mac."))
        }
        guard let text = payload.text, !text.isEmpty else {
            return showNotice(tr("The Mac clipboard is empty or is not text."))
        }
        if Self.isSensitive(payload) {
            pasteboard.writeSensitive(text, expiresAfter: Self.sensitiveLifetime)
            syncedChangeCount = pasteboard.changeCount
            showNotice(tr("Copied sensitive content from the Mac (this device only, cleared after %lld seconds).", Int(Self.sensitiveLifetime)))
            return
        }
        write(text)
    }

    /// Markers from nspasteboard.org that password managers on the Mac attach to the clipboard: it should not be synced everywhere.
    static let sensitiveTypes: Set<String> = [
        "org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType", "org.nspasteboard.AutoGeneratedType",
    ]
    static let sensitiveLifetime: TimeInterval = 90

    static func isSensitive(_ payload: PasteboardPayload) -> Bool {
        payload.representations.contains { sensitiveTypes.contains($0.uti) }
    }

    /// The server reports the clipboard was too large and was skipped (the session keeps running). Only report when we just asked.
    public func noteSkipped(bytes: Int) {
        let megabytes = Double(bytes) / 1_048_576
        showNotice(tr("The Mac clipboard is too large (%@ MB) and was skipped.", megabytes.formatted(.number.precision(.fractionLength(1)))))
    }

    /// `ServerCutText` from a standard server (Latin-1).
    ///
    /// The server pushes on its own, so we do **not** write straight to the device clipboard: a malicious or hijacked server could plant a
    /// command or path and wait for the user to paste it elsewhere, and Universal Clipboard would carry it to other devices. The text is
    /// written only when the user just copied on the Mac (automatic mode) or tapped Get; otherwise it is kept in memory.
    public func receive(cutText text: String) {
        latestStandardText = text
        guard mode == .shared, !text.isEmpty, let until = standardPushAcceptedUntil, ContinuousClock.now <= until else { return }
        standardPushAcceptedUntil = nil
        write(text)
    }

    private func write(_ text: String) {
        pasteboard.string = text // writing needs no permission
        syncedChangeCount = pasteboard.changeCount // we just wrote it: the next ⌘V need not send it back to the Mac
        showNotice(tr("Copied %lld characters from the Mac.", text.count))
    }

    // MARK: - Notices

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
