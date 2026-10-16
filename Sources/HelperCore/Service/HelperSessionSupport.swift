#if os(macOS)
import Foundation
import LinkProtocol

/// The shared objects one `HelperSession` works with. Everything here is owned by `HelperService`.
struct HelperResources: Sendable {
    var tracker: WindowTracker
    var catalog: AppCatalog
    var injector: InputInjector
    var menus: MenuReader
    var inbox: FileInbox?
    var capture: any CaptureSystem
    var makeEncoder: @Sendable (EncoderSettings) throws -> any VideoEncoding
    var makeClipboard: @Sendable () -> PasteboardBridge
    var audio: HelperAudio?
    var permissions: any PermissionProbe
    var options: HelperServiceOptions
}

/// Conditions a new session is told about right after the snapshot.
struct HelperConditions: Sendable, Equatable {
    var accessibility: LinkPermissionState
    var screenRecording: LinkPermissionState
    var stage: LinkStageState
    var macLocked: Bool
    var secureInput: Bool
    var frontmostPID: Int32?
}

/// What a session needs from the service, beyond the shared objects: everything that spans sessions.
protocol HelperSessionHost: Sendable {
    func conditions() async -> HelperConditions
    /// The set of windows `session` streams changed. The host keeps the union for input authorisation and manages or
    /// releases windows on the stage when the first session starts or the last one stops streaming them.
    func subscriptionsChanged(session: UInt64, added: Set<WindowID>, removed: Set<WindowID>) async
    func requestStageSize(window: WindowID, size: LinkSize) async
    func reportPermissionDenied(_ kind: LinkPermissionKind) async
    /// Posts `message` as input. Key and text events go to `keyboardWindow` (the session's focused window).
    func inject(_ message: LinkMessage, keyboardWindow: WindowID?) async
    func claimAudio(pid: Int32, session: UInt64) async -> Bool
    func releaseAudio(pid: Int32, session: UInt64) async
    /// A file transfer id that is unique across sessions (iPads choose theirs independently).
    func allocateTransfer() async -> TransferID
}

/// A small FIFO async mutex.
final class AsyncGate: @unchecked Sendable {
    private let lock = NSLock()
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func run<T: Sendable>(_ body: @Sendable () async -> T) async -> T {
        await acquire()
        let result = await body()
        release()
        return result
    }

    private func acquire() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let ready: Bool = lock.withLock {
                if busy { waiters.append(continuation); return false }
                busy = true
                return true
            }
            if ready { continuation.resume() }
        }
    }

    private func release() {
        let next: CheckedContinuation<Void, Never>? = lock.withLock {
            if waiters.isEmpty { busy = false; return nil }
            return waiters.removeFirst()
        }
        next?.resume()
    }
}
#endif
