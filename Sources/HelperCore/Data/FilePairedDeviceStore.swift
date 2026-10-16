#if os(macOS)
import Darwin
import Foundation
import LinkTransport
import os

/// A `PairedDeviceStore` kept in a JSON file (the helper keeps it in Application Support).
///
/// The SPKI hashes and device names are not secret (the private keys live in the Keychain), but the file decides who may
/// connect, so it is written atomically with mode 0600 inside a 0700 folder, never follows a symbolic link, and is size-capped
/// when read. Lookups come from memory. A change that cannot be saved is not kept for `add` (fail closed: a device that would
/// vanish after a restart is not trusted now) and is kept for `revoke` (fail safe: a revoked device stays revoked).
public final class FilePairedDeviceStore: PairedDeviceStore, @unchecked Sendable {
    public static let maxFileBytes = 1 << 20
    public static let maxNameBytes = 64
    private static let formatVersion = 1

    private struct FileFormat: Codable {
        var version: Int
        var devices: [PairedDevice]
    }

    private let url: URL
    private let lock = NSLock()
    private var devices: [Data: PairedDevice] = [:]
    private let log = Logger(subsystem: "app.screon.helper", category: "paired-devices")

    /// `Application Support/Screon Helper/paired-devices.json`.
    public static func defaultURL() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return base.appending(path: "Screon Helper", directoryHint: .isDirectory).appending(path: "paired-devices.json", directoryHint: .notDirectory)
    }

    /// Loads the file if it exists. An unreadable or malformed file is moved aside (`.corrupt`) and the store starts empty:
    /// fewer trusted devices, never more.
    public init(url: URL) {
        self.url = url
        var loaded: [Data: PairedDevice] = [:]
        switch Self.readFile(url) {
        case .missing: break
        case .loaded(let list):
            for device in list where device.spkiHash.count == 32 && loaded.count < InMemoryPairedDeviceStore.maxDevices {
                var clean = device
                clean.name = Self.clean(device.name)
                loaded[clean.spkiHash] = clean
            }
        case .corrupt:
            let aside = url.deletingLastPathComponent().appending(path: url.lastPathComponent + ".corrupt", directoryHint: .notDirectory)
            try? FileManager.default.removeItem(at: aside)
            try? FileManager.default.moveItem(at: url, to: aside)
            log.error("paired-devices file was unreadable; moved aside and starting empty")
        }
        devices = loaded
    }

    public func device(spkiHash: Data) -> PairedDevice? { lock.withLock { devices[spkiHash] } }

    public func all() -> [PairedDevice] { lock.withLock { devices.values.sorted { $0.pairedAt < $1.pairedAt } } }

    public func add(_ device: PairedDevice) throws {
        try lock.withLock {
            guard device.spkiHash.count == 32 else { throw FilePairedDeviceStoreError.invalidHash }
            guard devices[device.spkiHash] != nil || devices.count < InMemoryPairedDeviceStore.maxDevices else { throw PairedStoreError.full }
            let previous = devices[device.spkiHash]
            var clean = device
            clean.name = Self.clean(device.name)
            devices[clean.spkiHash] = clean
            do { try save() } catch {
                devices[clean.spkiHash] = previous
                throw error
            }
        }
    }

    @discardableResult public func revoke(spkiHash: Data) throws -> Bool {
        try lock.withLock {
            guard devices.removeValue(forKey: spkiHash) != nil else { return false }
            try save()
            return true
        }
    }

    /// Changes the display name of a paired device. Returns whether the device exists.
    @discardableResult public func rename(spkiHash: Data, to name: String) throws -> Bool {
        guard let existing = device(spkiHash: spkiHash) else { return false }
        try add(PairedDevice(spkiHash: spkiHash, name: name, pairedAt: existing.pairedAt))
        return true
    }

    // MARK: File access

    /// Printable, at most 64 bytes, never empty.
    static func clean(_ name: String) -> String {
        var result = ""
        for scalar in name.unicodeScalars where !CharacterSet.controlCharacters.contains(scalar) {
            let next = result + String(Character(scalar))
            if next.utf8.count > maxNameBytes { break }
            result = next
        }
        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "iPad" : trimmed
    }

    private enum ReadResult {
        case missing
        case loaded([PairedDevice])
        case corrupt
    }

    private static func readFile(_ url: URL) -> ReadResult {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW)
        if fd < 0 { return errno == ENOENT ? .missing : .corrupt }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size <= maxFileBytes else { return .corrupt }
        var data = Data(count: Int(info.st_size))
        let count = data.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
        guard count == Int(info.st_size) else { return .corrupt }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let file = try? decoder.decode(FileFormat.self, from: data), file.version == formatVersion else { return .corrupt }
        return .loaded(file.devices)
    }

    private func save() throws {
        let folder = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(FileFormat(version: Self.formatVersion, devices: devices.values.sorted { $0.pairedAt < $1.pairedAt }))

        let temp = folder.appending(path: ".\(url.lastPathComponent).\(UUID().uuidString).tmp", directoryHint: .notDirectory)
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw FilePairedDeviceStoreError.io(errno) }
        var failure: Int32?
        let written = data.withUnsafeBytes { raw -> Int in
            var offset = 0
            while offset < raw.count {
                let n = write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    return -1
                }
                offset += n
            }
            return offset
        }
        if written < 0 || fsync(fd) != 0 { failure = errno }
        close(fd)
        if failure == nil, Darwin.rename(temp.path, url.path) != 0 { failure = errno }
        if let failure {
            unlink(temp.path)
            throw FilePairedDeviceStoreError.io(failure)
        }
    }
}

public enum FilePairedDeviceStoreError: Error, Equatable {
    case invalidHash
    case io(Int32)
}
#endif
