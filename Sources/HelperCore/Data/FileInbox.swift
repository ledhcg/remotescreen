#if os(macOS)
import AppKit
import CryptoKit
import Darwin
import Foundation
import UniformTypeIdentifiers
import LinkProtocol
import os

public enum FileInboxError: Error, Equatable {
    case invalidName
    case tooLarge
    case quotaExceeded
    case tooManyTransfers
    case duplicateTransfer
    case unknownTransfer
    case nonContiguous(expected: UInt64, got: UInt64)
    case chunkTooLarge
    case sizeMismatch
    case hashMismatch
    /// The resolved path would leave the transfer's folder.
    case unsafePath
    /// The inbox, a transfer folder or a file is a symbolic link.
    case symlink
    case io(Int32)
    case notOpenable
}

/// Opens a delivered file with an application (`NSWorkspace.open(_:withApplicationAt:)` in production).
public protocol FileOpening: Sendable {
    func open(_ file: URL, withApplicationBundleID bundleID: String) async throws
}

public struct InboxFile: Sendable, Equatable {
    public var transfer: TransferID
    public var url: URL
    public var name: String
    public var size: UInt64
    public var targetBundleID: String?
    public var completedAt: Date
}

/// Receives files from the iPad into a folder only the helper owns: `<root>/<transfer>/<name>`.
///
/// - The name goes through `LinkFileName.validated`, the final path is standardized and must stay inside the transfer folder,
///   and nothing in the chain may be a symbolic link (files are created with `O_EXCL | O_NOFOLLOW`).
/// - Data is written to a hidden `.partial` file (a name `LinkFileName` can never produce), and only renamed to the real name once
///   the size and SHA-256 match. Chunks must arrive contiguously from offset 0.
/// - Total storage is capped (2 GiB), concurrent transfers are capped, and folders older than 24 hours are removed.
/// - Opening is refused for executable and script types, whatever the iPad asks.
public actor FileInbox {
    public static let defaultQuota: UInt64 = 2 << 30
    public static let defaultRetention: TimeInterval = 24 * 3600
    static let partialName = ".partial"

    private struct Active {
        var directory: URL
        var partial: URL
        var final: URL
        var name: String
        var declared: UInt64
        var received: UInt64 = 0
        var hasher = SHA256()
        var descriptor: Int32
        var target: String?
    }

    private let root: URL
    private let quota: UInt64
    private let maxConcurrent: Int
    private let retention: TimeInterval
    private let opener: (any FileOpening)?
    private let now: @Sendable () -> Date
    private let log = Logger(subsystem: "app.screon.helper", category: "files")
    private var active: [TransferID: Active] = [:]
    private var completed: [TransferID: InboxFile] = [:]

    /// Creates the inbox folder if needed. Throws `.symlink` if `root` itself is a symbolic link.
    public init(
        root: URL, quota: UInt64 = FileInbox.defaultQuota, maxConcurrent: Int = 4, retention: TimeInterval = FileInbox.defaultRetention,
        opener: (any FileOpening)? = nil, now: @escaping @Sendable () -> Date = { Date() }
    ) throws {
        if Self.isSymlink(root) { throw FileInboxError.symlink }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if Self.isSymlink(root) { throw FileInboxError.symlink }
        self.root = root.resolvingSymlinksInPath().standardizedFileURL
        self.quota = quota; self.maxConcurrent = max(1, maxConcurrent); self.retention = retention
        self.opener = opener; self.now = now
    }

    /// `Application Support/Screon Helper/Inbox`.
    public static func defaultRoot() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return base.appending(path: "Screon Helper", directoryHint: .isDirectory).appending(path: "Inbox", directoryHint: .isDirectory)
    }

    public var rootURL: URL { root }
    public var activeTransfers: Int { active.count }

    // MARK: Receiving

    public func begin(_ message: LinkFileBegin) throws {
        let name: String
        do { name = try LinkFileName.validated(message.name) } catch { throw FileInboxError.invalidName }
        guard message.size <= LinkLimits.maxFileBytes else { throw FileInboxError.tooLarge }
        guard active[message.transfer] == nil, completed[message.transfer] == nil else { throw FileInboxError.duplicateTransfer }
        guard active.count < maxConcurrent else { throw FileInboxError.tooManyTransfers }
        if Self.isSymlink(root) { throw FileInboxError.symlink }

        let reserved = active.values.reduce(UInt64(0)) { $0 + $1.declared }
        let (sum, overflow) = (usedBytes() + reserved).addingReportingOverflow(message.size)
        guard !overflow, sum <= quota else { throw FileInboxError.quotaExceeded }

        let directory = root.appending(path: String(message.transfer.rawValue), directoryHint: .isDirectory)
        let final = directory.appending(path: name, directoryHint: .notDirectory)
        let partial = directory.appending(path: Self.partialName, directoryHint: .notDirectory)
        guard Self.isContained(final, in: directory), Self.isContained(directory, in: root) else { throw FileInboxError.unsafePath }

        // mkdir fails with EEXIST for an existing folder, a file or a symlink planted under that name.
        guard mkdir(directory.path, 0o700) == 0 else {
            throw errno == EEXIST ? FileInboxError.duplicateTransfer : FileInboxError.io(errno)
        }
        let descriptor = Darwin.open(partial.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            let code = errno
            try? FileManager.default.removeItem(at: directory)
            throw code == ELOOP ? FileInboxError.symlink : FileInboxError.io(code)
        }
        active[message.transfer] = Active(
            directory: directory, partial: partial, final: final, name: name, declared: message.size,
            descriptor: descriptor, target: message.targetBundleID
        )
    }

    public func append(_ chunk: LinkFileChunk) throws {
        guard var transfer = active[chunk.transfer] else { throw FileInboxError.unknownTransfer }
        guard chunk.data.count <= LinkLimits.maxFileChunkBytes else { abort(chunk.transfer); throw FileInboxError.chunkTooLarge }
        guard chunk.offset == transfer.received else {
            let expected = transfer.received
            abort(chunk.transfer)
            throw FileInboxError.nonContiguous(expected: expected, got: chunk.offset)
        }
        let (end, overflow) = transfer.received.addingReportingOverflow(UInt64(chunk.data.count))
        guard !overflow, end <= transfer.declared else { abort(chunk.transfer); throw FileInboxError.sizeMismatch }
        do { try Self.writeAll(chunk.data, to: transfer.descriptor) } catch {
            abort(chunk.transfer)
            throw error
        }
        transfer.hasher.update(data: chunk.data)
        transfer.received = end
        active[chunk.transfer] = transfer
    }

    /// Verifies size and SHA-256, then moves the file to its final name.
    @discardableResult
    public func finish(transfer id: TransferID, sha256: LinkBytes32) throws -> InboxFile {
        guard let transfer = active[id] else { throw FileInboxError.unknownTransfer }
        guard transfer.received == transfer.declared else { abort(id); throw FileInboxError.sizeMismatch }
        let digest = Data(transfer.hasher.finalize())
        guard digest == sha256.data else { abort(id); throw FileInboxError.hashMismatch }
        Darwin.close(transfer.descriptor)
        active[id] = nil
        guard !Self.exists(transfer.final), rename(transfer.partial.path, transfer.final.path) == 0 else {
            try? FileManager.default.removeItem(at: transfer.directory)
            throw FileInboxError.io(errno)
        }
        let file = InboxFile(
            transfer: id, url: transfer.final, name: transfer.name, size: transfer.declared,
            targetBundleID: transfer.target, completedAt: now()
        )
        completed[id] = file
        return file
    }

    /// Drops a transfer and its partial data (connection lost, user cancelled).
    public func abort(_ id: TransferID) {
        guard let transfer = active.removeValue(forKey: id) else { return }
        Darwin.close(transfer.descriptor)
        try? FileManager.default.removeItem(at: transfer.directory)
    }

    public func abortAll() {
        for id in Array(active.keys) { abort(id) }
    }

    // MARK: Opening

    /// Opens a delivered file with the application the iPad named. Allowed only when the file is a plain document type
    /// (allow-list, `isAllowedDocument`), no extension segment is executable or a script, the named application is not
    /// one that runs code or installs things (`refusedHandlers`), and the opener confirms that application declares it can
    /// open the file. The iPad never gets to pick an arbitrary handler for an arbitrary file.
    public func open(transfer id: TransferID) async throws {
        guard let file = completed[id], let opener else { throw FileInboxError.unknownTransfer }
        guard let bundleID = file.targetBundleID, Self.isPlausibleBundleID(bundleID),
              !Self.refusedHandlers.contains(bundleID.lowercased()) else { throw FileInboxError.notOpenable }
        guard !Self.isDangerousToOpen(name: file.name), Self.isAllowedDocument(name: file.name) else {
            throw FileInboxError.notOpenable
        }
        let path = file.url
        guard Self.isContained(path, in: root), !Self.isSymlink(path.deletingLastPathComponent()), !Self.isSymlink(path),
              Self.isRegularFile(path) else { throw FileInboxError.unsafePath }
        try await opener.open(path, withApplicationBundleID: bundleID)
    }

    // MARK: Housekeeping

    /// Removes transfer folders older than the retention time (24 hours) and anything unexpected in the inbox.
    /// Returns how many were removed. Folders of running transfers are kept. Call at launch and now and then.
    @discardableResult
    public func cleanup() -> Int {
        let activeNames = Set(active.keys.map { String($0.rawValue) })
        let entries = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        var removed = 0
        for entry in entries where !activeNames.contains(entry.lastPathComponent) {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: entry.path),
                  let modified = attributes[.modificationDate] as? Date else { continue }
            if now().timeIntervalSince(modified) > retention {
                // removeItem on a symbolic link removes the link, never its target.
                if (try? FileManager.default.removeItem(at: entry)) != nil { removed += 1 }
            }
        }
        for (id, file) in completed where !Self.exists(file.url) { completed[id] = nil }
        return removed
    }

    /// Bytes stored in the inbox (regular files only, links are not followed).
    public func usedBytes() -> UInt64 {
        var total: UInt64 = 0
        let entries = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        for entry in entries {
            guard let kind = Self.fileType(entry) else { continue }
            if kind == .typeRegular {
                total += Self.size(entry)
            } else if kind == .typeDirectory {
                for child in (try? FileManager.default.contentsOfDirectory(at: entry, includingPropertiesForKeys: nil)) ?? []
                where Self.fileType(child) == .typeRegular {
                    total += Self.size(child)
                }
            }
        }
        return total
    }

    // MARK: Helpers

    /// True when `url`, after standardization, is strictly inside `directory` and contains no `..` component.
    static func isContained(_ url: URL, in directory: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let base = directory.standardizedFileURL.path
        guard !url.pathComponents.contains(".."), !path.contains("/../") else { return false }
        return path.hasPrefix(base.hasSuffix("/") ? base : base + "/") && path.count > base.count + 1
    }

    static func fileType(_ url: URL) -> FileAttributeType? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType
    }

    static func isSymlink(_ url: URL) -> Bool { fileType(url) == .typeSymbolicLink }
    static func isRegularFile(_ url: URL) -> Bool { fileType(url) == .typeRegular }
    static func exists(_ url: URL) -> Bool { fileType(url) != nil }

    static func size(_ url: URL) -> UInt64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.uint64Value ?? 0
    }

    static func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw FileInboxError.io(errno)
                }
                offset += written
            }
        }
    }

    static func isPlausibleBundleID(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= LinkLimits.maxBundleIDBytes
            && id.unicodeScalars.allSatisfy { $0.isASCII && ($0.properties.isAlphabetic || ("0"..."9").contains($0) || $0 == "." || $0 == "-") }
    }

    /// Types that run code or change the system when opened, plus link files that can launch things.
    static let dangerousExtensions: Set<String> = [
        "app", "command", "sh", "bash", "zsh", "csh", "ksh", "fish", "tool", "pkg", "mpkg", "dmg", "iso", "terminal", "scpt", "scptd",
        "applescript", "workflow", "action", "jar", "py", "pl", "rb", "php", "js", "jse", "ps1", "bat", "cmd", "exe", "msi", "vbs",
        "wsf", "dylib", "so", "plugin", "kext", "xpc", "bundle", "service", "prefpane", "saver", "webloc", "inetloc", "fileloc",
        "url", "mobileconfig", "configprofile", "definition", "osax", "lpx", "qlgenerator", "mdimporter", "appex", "framework",
    ]

    /// Applications that run code, scripts or installers, or change system settings, whatever file they are given.
    /// Lower-cased bundle identifiers.
    static let refusedHandlers: Set<String> = [
        "com.apple.terminal", "com.googlecode.iterm2", "com.apple.scripteditor2", "com.apple.automator",
        "com.apple.automator.automator-application-stub", "com.apple.installer", "com.apple.archiveutility",
        "org.python.pythonlauncher", "com.apple.systempreferences", "com.apple.systemsettings", "com.apple.shortcuts",
        "com.apple.dt.xcode", "com.apple.diskimagemounter", "com.apple.keychainaccess",
        "com.apple.finder",
    ].reduce(into: Set<String>()) { $0.insert($1.lowercased()) }

    /// The content allow-list: images, PDF, audio/video, office documents, rich text and plain text that is not source
    /// code or a script. The type comes from the last extension; archives, HTML, disk images and anything unknown are refused.
    static func isAllowedDocument(name: String) -> Bool {
        let parts = name.split(separator: ".", omittingEmptySubsequences: true)
        guard parts.count > 1, let ext = parts.last, let type = UTType(filenameExtension: String(ext)) else { return false }
        if type.conforms(to: .sourceCode) || type.conforms(to: .script) || type.conforms(to: .executable)
            || type.conforms(to: .archive) || type.conforms(to: .diskImage) || type.conforms(to: .html)
            || type.conforms(to: .applicationBundle) || type.conforms(to: .package) {
            return false
        }
        let allowed: [UTType] = [.image, .pdf, .audiovisualContent, .presentation, .spreadsheet, .rtf, .rtfd, .plainText]
        if allowed.contains(where: { type.conforms(to: $0) }) { return true }
        // Office and iWork documents that do not declare one of the generic types above.
        let documentExtensions: Set<String> = ["doc", "docx", "pages", "numbers", "key", "odt", "ods", "odp", "epub"]
        return documentExtensions.contains(ext.lowercased())
    }

    static func isDangerousToOpen(name: String) -> Bool {
        let parts = name.lowercased().split(separator: ".", omittingEmptySubsequences: true)
        guard parts.count > 1 else { return false }
        // Every extension segment counts: "evil.app.txt" is harmless but "report.pdf.command" is not.
        return parts.dropFirst().contains { dangerousExtensions.contains(String($0)) }
    }
}

/// `NSWorkspace.open(_:withApplicationAt:)`. The file is marked as downloaded (quarantined) first, so Gatekeeper still judges it.
public struct WorkspaceFileOpener: FileOpening {
    public init() {}

    public func open(_ file: URL, withApplicationBundleID bundleID: String) async throws {
        guard let application = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            throw FileInboxError.notOpenable
        }
        // The named application must declare that it opens this kind of file.
        let capable = NSWorkspace.shared.urlsForApplications(toOpen: file).map(\.standardizedFileURL)
        guard capable.contains(application.standardizedFileURL) else { throw FileInboxError.notOpenable }
        var values = URLResourceValues()
        values.quarantineProperties = ["LSQuarantineType": "LSQuarantineTypeOtherDownload"]
        var target = file
        try? target.setResourceValues(values)
        _ = try await NSWorkspace.shared.open([file], withApplicationAt: application, configuration: NSWorkspace.OpenConfiguration())
    }
}
#endif
