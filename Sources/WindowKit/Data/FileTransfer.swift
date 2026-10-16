import CryptoKit
import Foundation
import LinkProtocol

/// Rules for files the person drops onto a window.
public enum FileDropPolicy {
    /// Files waiting plus the one being sent. More are refused, so a drop of a whole folder cannot queue thousands.
    public static let maxQueued = 8
    /// Size of one `file.chunk`.
    public static let chunkBytes = 256 << 10
    /// Bytes sent before waiting for the Mac to have read them (flow control; keeps the control stream free for other messages).
    public static let windowBytes = 2 << 20

    /// A name the Mac's inbox accepts (`LinkFileName`), made from whatever the source called the file, or `nil` when nothing usable
    /// is left. Path separators and colons become `-`; control, bidirectional and invisible characters are removed; leading dots and
    /// trailing dots and spaces are trimmed; an over-long name is shortened but keeps its extension.
    public static func transferName(from suggested: String) -> String? {
        var scalars = String.UnicodeScalarView()
        for scalar in suggested.unicodeScalars {
            switch scalar.value {
            case 0x2F, 0x5C, 0x3A: scalars.append("-")
            case 0x00...0x1F, 0x7F...0x9F, 0x200B...0x200F, 0x202A...0x202E, 0x2060...0x2069, 0xFEFF, 0xFFF9...0xFFFB: continue
            default: scalars.append(scalar)
            }
        }
        var name = String(scalars)
        while let first = name.unicodeScalars.first, first == "." || first == " " || first.properties.isGraphemeExtend {
            name.unicodeScalars.removeFirst()
        }
        while let last = name.unicodeScalars.last, last == "." || last == " " { name.unicodeScalars.removeLast() }
        if name.utf8.count > LinkLimits.maxFileNameBytes { name = shorten(name) }
        return LinkFileName.isValid(name) ? name : nil
    }

    private static func shorten(_ name: String) -> String {
        let ext = (name as NSString).pathExtension
        let suffix = ext.isEmpty || ext.utf8.count > 16 ? "" : "." + ext
        var base = String(name.dropLast(suffix.count))
        while (base + suffix).utf8.count > LinkLimits.maxFileNameBytes, !base.isEmpty { base.removeLast() }
        return base + suffix
    }

    /// An empty file has nothing to send; one over the protocol's limit would be refused by the Mac.
    public static func isAcceptable(size: UInt64) -> Bool { size > 0 && size <= LinkLimits.maxFileBytes }
}

/// Where the bytes of a file come from. `read` returns up to `length` bytes starting at `offset`; fewer than asked only at the end.
public protocol FileChunkSource: Sendable {
    var size: UInt64 { get }
    func read(offset: UInt64, length: Int) throws -> Data
}

public struct FileTransferProgress: Sendable, Equatable {
    public var sentBytes: UInt64
    public var totalBytes: UInt64
    public var fraction: Double { totalBytes == 0 ? 0 : min(Double(sentBytes) / Double(totalBytes), 1) }
}

public enum FileSendResult: Sendable, Equatable {
    case sent
    /// The outbound queue is full: wait a moment and send the same message again.
    case busy
    case failed
}

public enum FileTransferOutcome: Sendable, Equatable {
    /// Everything was sent. The Mac does not report back, so this does not say the file was opened.
    case sent
    case cancelled
    case failed(FileTransferFailure)
}

public enum FileTransferFailure: Sendable, Equatable {
    case unreadable
    /// The file got shorter or longer while it was being read.
    case changedWhileSending
    case linkLost
    case timedOut
}

/// Sends one file as `file.begin`, `file.chunk`s and `file.end` with the SHA-256 of the whole file.
///
/// Flow control: after every `FileDropPolicy.windowBytes` it calls `barrier`, which must return only when the Mac has read everything sent so
/// far (a ping answered in order on the same stream). Cancelling after `file.begin` ends the transfer with a digest that cannot match,
/// and the Mac discards what it has; there is no separate abort message.
public enum FileTransferSender {
    /// How long one message may stay `busy`, and how long a barrier may take, before the transfer fails.
    public static let stallLimit: Duration = .seconds(30)

    public static func run(
        transfer: TransferID, name: String, targetBundleID: String?, source: any FileChunkSource,
        send: @Sendable (LinkMessage) async -> FileSendResult,
        barrier: @Sendable () async -> Bool,
        progress: @Sendable (FileTransferProgress) -> Void,
        isCancelled: @Sendable () -> Bool,
        pause: @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) async -> FileTransferOutcome {
        let total = source.size
        guard FileDropPolicy.isAcceptable(size: total), LinkFileName.isValid(name) else { return .failed(.unreadable) }
        if isCancelled() { return .cancelled }

        func deliver(_ message: LinkMessage) async -> FileTransferFailure? {
            var waited = Duration.zero
            while true {
                switch await send(message) {
                case .sent: return nil
                case .failed: return .linkLost
                case .busy:
                    guard waited < stallLimit else { return .timedOut }
                    await pause(.milliseconds(25))
                    waited += .milliseconds(25)
                }
            }
        }

        if let failure = await deliver(.fileBegin(LinkFileBegin(transfer: transfer, name: name, size: total, targetBundleID: targetBundleID))) {
            return .failed(failure)
        }
        var hasher = SHA256()
        var offset: UInt64 = 0
        var sinceBarrier = 0
        progress(FileTransferProgress(sentBytes: 0, totalBytes: total))

        func abandon(_ outcome: FileTransferOutcome) async -> FileTransferOutcome {
            // A digest that cannot match: the Mac drops the partial file.
            _ = await deliver(.fileEnd(transfer: transfer, sha256: LinkBytes32(repeating: 0)))
            return outcome
        }

        while offset < total {
            if isCancelled() { return await abandon(.cancelled) }
            let length = Int(min(UInt64(FileDropPolicy.chunkBytes), total - offset))
            let data: Data
            do { data = try source.read(offset: offset, length: length) } catch { return await abandon(.failed(.unreadable)) }
            guard data.count == length else { return await abandon(.failed(.changedWhileSending)) }
            hasher.update(data: data)
            if let failure = await deliver(.fileChunk(LinkFileChunk(transfer: transfer, offset: offset, data: data))) {
                return .failed(failure)
            }
            offset += UInt64(length)
            sinceBarrier += length
            progress(FileTransferProgress(sentBytes: offset, totalBytes: total))
            if sinceBarrier >= FileDropPolicy.windowBytes, offset < total {
                sinceBarrier = 0
                guard await barrier() else { return await abandon(.failed(.timedOut)) }
            }
        }
        // The file must not have grown either.
        if let extra = try? source.read(offset: total, length: 1), !extra.isEmpty { return await abandon(.failed(.changedWhileSending)) }
        if isCancelled() { return await abandon(.cancelled) }
        guard let digest = try? LinkBytes32(Data(hasher.finalize())) else { return .failed(.unreadable) }
        if let failure = await deliver(.fileEnd(transfer: transfer, sha256: digest)) {
            return .failed(failure)
        }
        return .sent
    }
}
