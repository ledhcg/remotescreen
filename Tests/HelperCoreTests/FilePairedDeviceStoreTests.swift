#if os(macOS)
import Foundation
import LinkTransport
import Testing
@testable import HelperCore

@Suite struct FilePairedDeviceStoreTests {
    let folder: URL
    var file: URL { folder.appending(path: "paired-devices.json") }

    init() {
        folder = FileManager.default.temporaryDirectory.appending(path: "screon-paired-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    private func hash(_ byte: UInt8) -> Data { Data(repeating: byte, count: 32) }
    private func device(_ byte: UInt8, _ name: String = "iPad") -> PairedDevice {
        PairedDevice(spkiHash: hash(byte), name: name, pairedAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(byte)))
    }

    @Test func persistsAcrossInstances() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = FilePairedDeviceStore(url: file)
        try store.add(device(1, "alice's iPad"))
        try store.add(device(2))
        let reloaded = FilePairedDeviceStore(url: file)
        #expect(reloaded.all().map(\.name) == ["alice's iPad", "iPad"])
        #expect(reloaded.device(spkiHash: hash(1))?.name == "alice's iPad")
    }

    @Test func fileAndFolderArePrivate() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = FilePairedDeviceStore(url: file)
        try store.add(device(1))
        let fileMode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        let folderMode = try FileManager.default.attributesOfItem(atPath: folder.path)[.posixPermissions] as? Int
        #expect(fileMode == 0o600)
        #expect(folderMode == 0o700)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".tmp") }
        #expect(leftovers.isEmpty)
    }

    @Test func revokePersistsAndReportsMissing() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = FilePairedDeviceStore(url: file)
        try store.add(device(1))
        #expect(try store.revoke(spkiHash: hash(1)))
        #expect(try store.revoke(spkiHash: hash(1)) == false)
        #expect(FilePairedDeviceStore(url: file).all().isEmpty)
    }

    @Test func renameKeepsPairingDate() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = FilePairedDeviceStore(url: file)
        try store.add(device(1, "old"))
        #expect(try store.rename(spkiHash: hash(1), to: "  Studio iPad \u{7}  "))
        #expect(store.device(spkiHash: hash(1))?.name == "Studio iPad")
        #expect(store.device(spkiHash: hash(1))?.pairedAt == device(1).pairedAt)
        #expect(try store.rename(spkiHash: hash(9), to: "x") == false)
    }

    @Test func nameIsBoundedAndNeverEmpty() {
        #expect(FilePairedDeviceStore.clean(String(repeating: "a", count: 500)).utf8.count == 64)
        #expect(FilePairedDeviceStore.clean("\u{0}\u{1}") == "iPad")
        #expect(FilePairedDeviceStore.clean(String(repeating: "\u{111}", count: 100)).utf8.count <= 64)
    }

    @Test func rejectsShortHashAndFullStore() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = FilePairedDeviceStore(url: file)
        #expect(throws: FilePairedDeviceStoreError.invalidHash) {
            try store.add(PairedDevice(spkiHash: Data([1, 2, 3]), name: "x", pairedAt: Date()))
        }
        for i in 0..<InMemoryPairedDeviceStore.maxDevices { try store.add(device(UInt8(i))) }
        #expect(throws: PairedStoreError.full) { try store.add(device(200)) }
        try store.add(device(0, "renamed"))  // an existing device can still be updated
    }

    @Test func corruptFileIsMovedAsideAndStoreStartsEmpty() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: file)
        let store = FilePairedDeviceStore(url: file)
        #expect(store.all().isEmpty)
        #expect(FileManager.default.fileExists(atPath: file.path + ".corrupt"))
        try store.add(device(1))
        #expect(FilePairedDeviceStore(url: file).all().count == 1)
    }

    @Test func oversizedFileAndSymlinkAreRefused() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(repeating: 0x20, count: FilePairedDeviceStore.maxFileBytes + 1).write(to: file)
        #expect(FilePairedDeviceStore(url: file).all().isEmpty)
        try? FileManager.default.removeItem(at: file)
        let target = folder.appending(path: "target.json")
        try FilePairedDeviceStore(url: target).add(device(1))
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
        #expect(FilePairedDeviceStore(url: file).all().isEmpty)
    }

    @Test func wrongVersionAndBadHashEntriesAreIgnored() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(#"{"version":2,"devices":[]}"#.utf8).write(to: file)
        #expect(FilePairedDeviceStore(url: file).all().isEmpty)
        try? FileManager.default.removeItem(at: file)
        let short = Data([1, 2, 3]).base64EncodedString()
        try Data(#"{"version":1,"devices":[{"spkiHash":"\#(short)","name":"x","pairedAt":"2024-01-01T00:00:00Z"}]}"#.utf8).write(to: file)
        #expect(FilePairedDeviceStore(url: file).all().isEmpty)
    }

    @Test func failedSaveDoesNotTrustTheDevice() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let store = FilePairedDeviceStore(url: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)  // rename onto a directory fails
        #expect(throws: FilePairedDeviceStoreError.self) { try store.add(device(1)) }
        #expect(store.device(spkiHash: hash(1)) == nil)
    }
}
#endif
