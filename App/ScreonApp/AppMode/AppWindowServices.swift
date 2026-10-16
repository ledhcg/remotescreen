import Foundation
import LinkProtocol
import Observation
import UIKit
import UniformTypeIdentifiers
import WindowKit
import os

/// The iOS pasteboard for `LinkClipboardSync`. Reading content can show the system "allow paste" prompt, so `LinkClipboardSync` reads
/// only when it sends; `typeIdentifiers` and `changeCount` never prompt.
@MainActor
final class LinkPasteboardAdapter: LinkPasteboard {
    private var pasteboard: UIPasteboard { .general }

    var changeCount: Int { pasteboard.changeCount }
    var typeIdentifiers: [String] { pasteboard.types }

    func read(wireType: String) -> Data? {
        switch wireType {
        case ClipboardWireTypes.text:
            return pasteboard.string.map { Data($0.utf8) }
        case ClipboardWireTypes.png:
            if let png = pasteboard.data(forPasteboardType: UTType.png.identifier) { return png }
            return pasteboard.image?.pngData()
        default:
            return pasteboard.data(forPasteboardType: wireType)
        }
    }

    func write(wireType: String, data: Data) {
        if wireType == ClipboardWireTypes.text, let text = String(data: data, encoding: .utf8) {
            pasteboard.string = text
        } else {
            pasteboard.setData(data, forPasteboardType: wireType)
        }
    }

    func writeSensitiveText(_ text: String, expiresAfter seconds: TimeInterval) {
        pasteboard.setItems(
            [[UTType.utf8PlainText.identifier: text]],
            options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(seconds)]
        )
    }
}

/// Reads a file in pieces for `FileTransferSender`. The file is a private copy made when it was dropped.
private struct FileHandleSource: FileChunkSource {
    let url: URL
    let size: UInt64

    func read(offset: UInt64, length: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: offset)
        return try handle.read(upToCount: length) ?? Data()
    }
}

/// The files being sent to the Mac for one connection: a queue of at most `FileDropPolicy.maxQueued`, one transfer at a time (the Mac
/// accepts only a few at once). Progress and the outcome are for the on-screen list; the Mac does not report whether it opened the file.
@MainActor
@Observable
final class AppFileTransfers {
    struct Item: Identifiable, Equatable {
        enum State: Equatable {
            case queued, sending, sent, cancelled, failed(FileTransferFailure), refused(Refusal)
        }
        enum Refusal: Equatable { case tooLarge, empty, folder, unreadable, queueFull, notConnected }

        let id: UInt32
        var name: String
        var state: State = .queued
        var fraction = 0.0
        var isFinished: Bool {
            switch state {
            case .queued, .sending: false
            default: true
            }
        }
    }

    private(set) var items: [Item] = []

    /// Posted (object: this) whenever the list or a progress value changes.
    nonisolated static let didChange = Notification.Name("app.screon.fileTransfersDidChange")

    /// Sends one message on the link; set by the connection.
    @ObservationIgnored var transport: (@Sendable (LinkMessage) async -> FileSendResult)?
    @ObservationIgnored var barrier: (@Sendable () async -> Bool)?
    @ObservationIgnored var isConnected: () -> Bool = { false }

    @ObservationIgnored private var pending: [UInt32: (url: URL, size: UInt64, target: String?)] = [:]
    @ObservationIgnored private let cancelFlags = OSAllocatedUnfairLock(initialState: Set<UInt32>())
    @ObservationIgnored private var nextID: UInt32 = 1
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private let log = Logger(subsystem: "app.screon", category: "files")

    nonisolated static let temporaryFolderName = "ScreonDroppedFiles"

    private static var temporaryFolder: URL {
        FileManager.default.temporaryDirectory.appending(path: temporaryFolderName, directoryHint: .isDirectory)
    }

    /// Removes copies left by an earlier run.
    static func cleanTemporaryFiles() { try? FileManager.default.removeItem(at: temporaryFolder) }

    /// Makes a private copy of a dropped file inside the drop handler (the provider deletes its own file when the handler returns), then
    /// queues it. Call on the main actor with the copy's URL.
    func enqueue(copiedFile url: URL, suggestedName: String, targetBundleID: String?) {
        let name = FileDropPolicy.transferName(from: suggestedName) ?? "file"
        func refuse(_ reason: Item.Refusal) {
            try? FileManager.default.removeItem(at: url)
            append(Item(id: allocateID(), name: name, state: .refused(reason)))
        }
        guard isConnected() else { return refuse(.notConnected) }
        guard items.filter({ !$0.isFinished }).count < FileDropPolicy.maxQueued else { return refuse(.queueFull) }
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey, .isRegularFileKey])
        guard values?.isDirectory != true, values?.isRegularFile == true else { return refuse(.folder) }
        guard let size = values?.fileSize.map(UInt64.init) else { return refuse(.unreadable) }
        guard size > 0 else { return refuse(.empty) }
        guard FileDropPolicy.isAcceptable(size: size) else { return refuse(.tooLarge) }
        let id = allocateID()
        pending[id] = (url, size, targetBundleID)
        append(Item(id: id, name: name))
        startWorkerIfNeeded()
    }

    /// Shows that a dropped item could not be sent, without sending anything.
    func refuse(name suggested: String, reason: Item.Refusal) {
        append(Item(id: allocateID(), name: FileDropPolicy.transferName(from: suggested) ?? suggested, state: .refused(reason)))
    }

    /// Stops a queued or running transfer. A running one ends with a digest the Mac rejects, so it discards the partial file.
    func cancel(_ id: UInt32) {
        guard let index = items.firstIndex(where: { $0.id == id }), !items[index].isFinished else { return }
        cancelFlags.withLock { _ = $0.insert(id) }
        if items[index].state == .queued {
            items[index].state = .cancelled
            if let entry = pending.removeValue(forKey: id) { try? FileManager.default.removeItem(at: entry.url) }
            changed()
        }
    }

    /// The connection ended: nothing queued can be sent.
    func connectionLost() {
        for item in items where !item.isFinished { cancel(item.id) }
    }

    /// Removes finished entries from the list.
    func dismissFinished() {
        items.removeAll { $0.isFinished }
        changed()
    }

    // MARK: Worker

    private func startWorkerIfNeeded() {
        guard worker == nil else { return }
        worker = Task { [weak self] in
            while let self, let next = self.nextQueued() { await self.run(next) }
            self?.worker = nil
        }
    }

    private func nextQueued() -> UInt32? { items.first { $0.state == .queued }?.id }

    private func run(_ id: UInt32) async {
        guard let entry = pending.removeValue(forKey: id), let index = items.firstIndex(where: { $0.id == id }) else { return }
        defer { try? FileManager.default.removeItem(at: entry.url) }
        guard let transport, let barrier else {
            items[index].state = .failed(.linkLost); changed(); return
        }
        items[index].state = .sending
        changed()
        let name = items[index].name
        let flags = cancelFlags
        let outcome = await FileTransferSender.run(
            transfer: TransferID(id), name: name, targetBundleID: entry.target, source: FileHandleSource(url: entry.url, size: entry.size),
            send: transport, barrier: barrier,
            progress: { progress in Task { @MainActor [weak self] in self?.update(id, fraction: progress.fraction) } },
            isCancelled: { flags.withLock { $0.contains(id) } }
        )
        guard let finalIndex = items.firstIndex(where: { $0.id == id }) else { return }
        switch outcome {
        case .sent: items[finalIndex].state = .sent; items[finalIndex].fraction = 1
        case .cancelled: items[finalIndex].state = .cancelled
        case .failed(let failure): items[finalIndex].state = .failed(failure)
        }
        cancelFlags.withLock { _ = $0.remove(id) }
        changed()
    }

    private func update(_ id: UInt32, fraction: Double) {
        guard let index = items.firstIndex(where: { $0.id == id }), items[index].state == .sending else { return }
        items[index].fraction = fraction
        changed()
    }

    private func allocateID() -> UInt32 {
        defer { nextID &+= 1; if nextID == 0 { nextID = 1 } }
        return nextID
    }

    private func append(_ item: Item) {
        items.append(item)
        // Finished entries do not pile up: keep the last few.
        let finished = items.filter(\.isFinished)
        if finished.count > 4, let first = finished.first, let index = items.firstIndex(where: { $0.id == first.id }) { items.remove(at: index) }
        changed()
    }

    private func changed() { NotificationCenter.default.post(name: Self.didChange, object: self) }
}

/// What a window of App Mode needs besides its picture: the clipboard and file transfers of the Mac connection it belongs to. Reached
/// through `WindowStream.services`, so the window view needs nothing from the scene that hosts it.
@MainActor
final class AppWindowServices {
    private let pasteboard = LinkPasteboardAdapter()
    private let defaults: UserDefaults
    private var sendMessage: (@MainActor (LinkMessage) -> Void)?
    private var richTypes = false

    private(set) var clipboard: LinkClipboardSync
    let files = AppFileTransfers()
    /// The Mac accepts pressure and tilt (`tablet`).
    private(set) var supportsTablet = false
    /// The Mac can receive files.
    private(set) var supportsFiles = false
    /// Resolves the bundle identifier of the app that owns a window, for "open the dropped file with this app".
    var bundleID: (WindowID) -> String? = { _ in nil }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        clipboard = LinkClipboardSync(pasteboard: pasteboard, isEnabled: false, richTypes: false, send: { _ in })
    }

    /// The person's clipboard mode (Settings): anything but "manual" shares. Same key as Screen Sharing sessions.
    private var sharingEnabled: Bool { defaults.string(forKey: "clipboardMode") != "manual" }

    /// A connection to the Mac is up with these negotiated features.
    func sessionStarted(capabilities: LinkCapabilities, send: @escaping @MainActor (LinkMessage) -> Void) {
        sendMessage = send
        richTypes = capabilities.contains(.clipboardRich)
        supportsTablet = capabilities.contains(.tablet)
        supportsFiles = capabilities.contains(.files)
        clipboard = LinkClipboardSync(pasteboard: pasteboard, isEnabled: sharingEnabled, richTypes: richTypes, send: { send($0) })
    }

    func sessionEnded() {
        sendMessage = nil
        supportsTablet = false
        supportsFiles = false
        clipboard.reset()
        files.connectionLost()
    }

    // MARK: Events from windows

    func sceneBecameActive() { refreshClipboardMode(); clipboard.sceneBecameActive() }
    func copyShortcutPressed() { refreshClipboardMode(); clipboard.copyShortcutPressed() }
    /// True when an offer went out, so the key should wait a moment.
    func pasteShortcutPressed() -> Bool { refreshClipboardMode(); return clipboard.pasteShortcutPressed() }
    func receive(clipboard message: LinkMessage) { refreshClipboardMode(); clipboard.receive(message) }

    private func refreshClipboardMode() { clipboard.isEnabled = sharingEnabled && sendMessage != nil }
}
