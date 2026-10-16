import CryptoKit
import Foundation
import LinkProtocol
import Testing
@testable import WindowKit

struct MemorySource: FileChunkSource {
    var bytes: Data
    var size: UInt64
    var failAt: UInt64?
    var growBy = 0

    init(_ bytes: Data, failAt: UInt64? = nil, declaredSize: UInt64? = nil) {
        self.bytes = bytes; self.size = declaredSize ?? UInt64(bytes.count); self.failAt = failAt
    }

    func read(offset: UInt64, length: Int) throws -> Data {
        if let failAt, offset >= failAt { throw CocoaError(.fileReadUnknown) }
        guard offset < UInt64(bytes.count) else { return Data() }
        return bytes.subdata(in: Int(offset)..<min(Int(offset) + length, bytes.count))
    }
}

final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _messages: [LinkMessage] = []
    private var _barriers = 0
    private var _busyLeft: Int
    private var _cancelAfterChunks: Int?
    private var _progress: [FileTransferProgress] = []
    init(busy: Int = 0, cancelAfterChunks: Int? = nil) { _busyLeft = busy; _cancelAfterChunks = cancelAfterChunks }

    var messages: [LinkMessage] { lock.withLock { _messages } }
    var barriers: Int { lock.withLock { _barriers } }
    var progress: [FileTransferProgress] { lock.withLock { _progress } }

    func send(_ message: LinkMessage) -> FileSendResult {
        lock.withLock {
            if _busyLeft > 0 { _busyLeft -= 1; return .busy }
            _messages.append(message)
            return .sent
        }
    }
    func barrier() -> Bool { lock.withLock { _barriers += 1; return true } }
    func note(_ p: FileTransferProgress) { lock.withLock { _progress.append(p) } }
    var cancelled: Bool {
        lock.withLock {
            guard let n = _cancelAfterChunks else { return false }
            return _messages.filter { if case .fileChunk = $0 { true } else { false } }.count >= n
        }
    }
}

@Suite struct FileTransferTests {
    static func data(_ count: Int) -> Data { Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) }) }

    func run(_ source: MemorySource, name: String = "report.pdf", recorder: Recorder = Recorder()) async -> (FileTransferOutcome, Recorder) {
        let outcome = await FileTransferSender.run(
            transfer: 5, name: name, targetBundleID: "com.example.viewer", source: source,
            send: { recorder.send($0) }, barrier: { recorder.barrier() }, progress: { recorder.note($0) },
            isCancelled: { recorder.cancelled }, pause: { _ in })
        return (outcome, recorder)
    }

    @Test func sendsBeginContiguousChunksAndTheDigestOfTheWholeFile() async throws {
        let payload = Self.data(FileDropPolicy.chunkBytes * 2 + 123)
        let (outcome, rec) = await run(MemorySource(payload))
        #expect(outcome == .sent)
        let messages = rec.messages
        #expect(messages.first == .fileBegin(LinkFileBegin(transfer: 5, name: "report.pdf", size: UInt64(payload.count), targetBundleID: "com.example.viewer")))
        var offset: UInt64 = 0
        var rebuilt = Data()
        for case .fileChunk(let chunk) in messages {
            #expect(chunk.transfer == 5 && chunk.offset == offset)
            #expect(chunk.data.count <= LinkLimits.maxFileChunkBytes)
            rebuilt.append(chunk.data)
            offset += UInt64(chunk.data.count)
        }
        #expect(rebuilt == payload)
        let digest = try LinkBytes32(Data(SHA256.hash(data: payload)))
        #expect(messages.last == .fileEnd(transfer: 5, sha256: digest))
    }

    @Test func progressGrowsToTheTotal() async {
        let payload = Self.data(FileDropPolicy.chunkBytes * 3)
        let (_, rec) = await run(MemorySource(payload))
        let progress = rec.progress
        #expect(progress.first?.sentBytes == 0)
        #expect(progress.last == FileTransferProgress(sentBytes: UInt64(payload.count), totalBytes: UInt64(payload.count)))
        #expect(zip(progress, progress.dropFirst()).allSatisfy { $0.sentBytes < $1.sentBytes })
        #expect(progress.last?.fraction == 1)
    }

    @Test func waitsForTheMacEveryWindowOfBytes() async {
        let chunks = FileDropPolicy.windowBytes / FileDropPolicy.chunkBytes
        let payload = Self.data(FileDropPolicy.chunkBytes * (chunks * 2 + 1))
        let (outcome, rec) = await run(MemorySource(payload))
        #expect(outcome == .sent)
        #expect(rec.barriers == 2)
    }

    @Test func aBusyQueueIsRetriedWithoutLosingOrReorderingChunks() async {
        let payload = Self.data(FileDropPolicy.chunkBytes + 5)
        let (outcome, rec) = await run(MemorySource(payload), recorder: Recorder(busy: 7))
        #expect(outcome == .sent)
        let offsets = rec.messages.compactMap { if case .fileChunk(let c) = $0 { c.offset } else { nil } }
        #expect(offsets == [0, UInt64(FileDropPolicy.chunkBytes)])
    }

    @Test func aQueueThatStaysBusyTimesOut() async {
        let (outcome, _) = await run(MemorySource(Self.data(10)), recorder: Recorder(busy: .max))
        #expect(outcome == .failed(.timedOut))
    }

    @Test func cancellingEndsTheTransferWithADigestThatCannotMatch() async {
        let payload = Self.data(FileDropPolicy.chunkBytes * 4)
        let (outcome, rec) = await run(MemorySource(payload), recorder: Recorder(cancelAfterChunks: 1))
        #expect(outcome == .cancelled)
        #expect(rec.messages.last == .fileEnd(transfer: 5, sha256: LinkBytes32(repeating: 0)))
        #expect(rec.messages.filter { if case .fileChunk = $0 { true } else { false } }.count == 1)
    }

    @Test func aFileThatChangesSizeIsAbandoned() async {
        let shorter = MemorySource(Self.data(1000), declaredSize: 5000)
        let (outcome, rec) = await run(shorter)
        #expect(outcome == .failed(.changedWhileSending))
        #expect(rec.messages.last == .fileEnd(transfer: 5, sha256: LinkBytes32(repeating: 0)))
        let longer = MemorySource(Self.data(1000), declaredSize: 500)
        let (outcome2, _) = await run(longer)
        #expect(outcome2 == .failed(.changedWhileSending))
    }

    @Test func anUnreadableFileFailsAndIsAbandoned() async {
        let (outcome, rec) = await run(MemorySource(Self.data(FileDropPolicy.chunkBytes * 2), failAt: UInt64(FileDropPolicy.chunkBytes)))
        #expect(outcome == .failed(.unreadable))
        #expect(rec.messages.last == .fileEnd(transfer: 5, sha256: LinkBytes32(repeating: 0)))
    }

    @Test func emptyOversizedAndBadlyNamedFilesSendNothing() async {
        let (empty, r1) = await run(MemorySource(Data()))
        #expect(empty == .failed(.unreadable) && r1.messages.isEmpty)
        let (huge, r2) = await run(MemorySource(Data(), declaredSize: LinkLimits.maxFileBytes + 1))
        #expect(huge == .failed(.unreadable) && r2.messages.isEmpty)
        let (bad, r3) = await run(MemorySource(Self.data(10)), name: "../etc/passwd")
        #expect(bad == .failed(.unreadable) && r3.messages.isEmpty)
    }

    // MARK: Names

    @Test func suggestedNamesAreMadeSafe() {
        #expect(FileDropPolicy.transferName(from: "report.pdf") == "report.pdf")
        #expect(FileDropPolicy.transferName(from: "Bản vẽ 2024.pdf") == "Bản vẽ 2024.pdf")
        #expect(FileDropPolicy.transferName(from: "../../etc/passwd") == "-..-etc-passwd")
        #expect(FileDropPolicy.transferName(from: ".hidden") == "hidden")
        #expect(FileDropPolicy.transferName(from: "a:b\\c.txt") == "a-b-c.txt")
        #expect(FileDropPolicy.transferName(from: "trailing. ") == "trailing")
        #expect(FileDropPolicy.transferName(from: "bad\u{0}name\n.txt") == "badname.txt")
        #expect(FileDropPolicy.transferName(from: "evil\u{202E}fdp.exe") == "evilfdp.exe")
        #expect(FileDropPolicy.transferName(from: "") == nil)
        #expect(FileDropPolicy.transferName(from: "...") == nil)
        #expect(FileDropPolicy.transferName(from: " \u{200B} ") == nil)
    }

    @Test func longNamesKeepTheirExtensionAndEveryResultIsValid() throws {
        let long = String(repeating: "é", count: 300) + ".pdf"
        let name = try #require(FileDropPolicy.transferName(from: long))
        #expect(name.hasSuffix(".pdf"))
        #expect(name.utf8.count <= LinkLimits.maxFileNameBytes)
        for sample in ["a", "x.y.z", "😀.png", "e\u{301}.txt", "\u{301}x", "name ", " name", "..a", "a/b"] {
            if let result = FileDropPolicy.transferName(from: sample) { #expect(LinkFileName.isValid(result), "\(sample) -> \(result)") }
        }
    }

    @Test func sizeLimits() {
        #expect(!FileDropPolicy.isAcceptable(size: 0))
        #expect(FileDropPolicy.isAcceptable(size: 1))
        #expect(FileDropPolicy.isAcceptable(size: LinkLimits.maxFileBytes))
        #expect(!FileDropPolicy.isAcceptable(size: LinkLimits.maxFileBytes + 1))
    }
}

@Suite struct VideoBitDepthTests {
    func sps(profile: UInt8, flags: UInt32 = 0) -> Data {
        Data([0x42, 0x01, 0x01, profile, UInt8(flags >> 24), UInt8((flags >> 16) & 0xFF), UInt8((flags >> 8) & 0xFF), UInt8(flags & 0xFF), 0, 0])
    }

    @Test func main10IsTenBitEverythingElseEight() {
        #expect(VideoBitDepth.bitDepth(codec: .hevc, parameterSets: [Data([0x40, 1, 2]), sps(profile: 2)]) == 10)
        #expect(VideoBitDepth.bitDepth(codec: .hevc, parameterSets: [sps(profile: 1, flags: 0x6000_0000)]) == 8)
        #expect(VideoBitDepth.bitDepth(codec: .hevc, parameterSets: [sps(profile: 0, flags: 0x2000_0000)]) == 10)
        #expect(VideoBitDepth.bitDepth(codec: .h264, parameterSets: [sps(profile: 2)]) == 8)
    }

    @Test func hostileParameterSetsGiveEight() {
        #expect(VideoBitDepth.bitDepth(codec: .hevc, parameterSets: []) == 8)
        #expect(VideoBitDepth.bitDepth(codec: .hevc, parameterSets: [Data()]) == 8)
        #expect(VideoBitDepth.bitDepth(codec: .hevc, parameterSets: [Data([0x42, 0x01])]) == 8)
        #expect(VideoBitDepth.bitDepth(codec: .hevc, parameterSets: [Data(repeating: 0xFF, count: 100)]) == 8)
    }
}
