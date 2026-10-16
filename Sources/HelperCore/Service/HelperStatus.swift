#if os(macOS)
import Foundation
import LinkProtocol

/// What the helper app's menu bar UI shows. A value type: the service publishes a new copy on every change.
public struct HelperStatus: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        case stopped
        case starting
        case running
        /// The service could not start (for example the listener could not bind). Developer-facing text.
        case failed(String)
    }

    public struct Session: Sendable, Equatable, Identifiable {
        public var id: UInt64
        /// Untrusted text from the iPad (already sanitised by the handshake): display it, never act on it.
        public var deviceName: String
        public var deviceID: Data
        public var connectedAt: Date
        public var subscribedWindows: Int
        public var resumed: Bool
    }

    /// A condition the person at the Mac may need to act on.
    public enum Issue: Sendable, Equatable, Hashable {
        case permissionMissing(LinkPermissionKind)
        case stageUnavailable
        case macLocked
        case secureInput
        case failed(String)

        /// User-facing text (localized).
        public var message: String {
            switch self {
            case .permissionMissing(.accessibility): tr("Accessibility permission is missing. Windows cannot be tracked or controlled.")
            case .permissionMissing(.screenRecording): tr("Screen Recording permission is missing. Windows cannot be streamed.")
            case .permissionMissing: tr("A permission that Screon Helper needs is missing.")
            case .stageUnavailable: tr("The virtual display is unavailable. Windows are resized where they are.")
            case .macLocked: tr("This Mac is locked. Unlock it to continue streaming windows.")
            case .secureInput: tr("Typing is blocked by a password field on this Mac.")
            case .failed: tr("Screon Helper could not start listening for iPads.")
            }
        }
    }

    public var phase: Phase = .stopped
    public var listeningPort: UInt16?
    public var sessions: [Session] = []
    public var accessibility: LinkPermissionState = .notDetermined
    public var screenRecording: LinkPermissionState = .notDetermined
    public var stage: LinkStageState = .inactive
    public var macLocked = false
    public var secureInput = false

    public init() {}

    public var isRunning: Bool { phase == .running }

    /// Conditions to show, most urgent first. Permission issues only count once the permission is known to be missing.
    public var issues: [Issue] {
        var result: [Issue] = []
        if case .failed(let reason) = phase { result.append(.failed(reason)) }
        if accessibility == .denied { result.append(.permissionMissing(.accessibility)) }
        if screenRecording == .denied { result.append(.permissionMissing(.screenRecording)) }
        if macLocked { result.append(.macLocked) }
        if stage == .unavailable { result.append(.stageUnavailable) }
        if secureInput { result.append(.secureInput) }
        return result
    }
}

/// Thread-safe holder of the published status; callbacks from `Stage`, the injector and the permission poller update it.
final class HelperStatusHub: @unchecked Sendable {
    private let lock = NSLock()
    private var value = HelperStatus()
    private var continuations: [UUID: AsyncStream<HelperStatus>.Continuation] = [:]

    var current: HelperStatus { lock.withLock { value } }

    /// Applies `change`; publishes only when something changed.
    @discardableResult
    func update(_ change: (inout HelperStatus) -> Void) -> HelperStatus {
        let (new, targets): (HelperStatus, [AsyncStream<HelperStatus>.Continuation]) = lock.withLock {
            let old = value
            change(&value)
            return (value, value == old ? [] : Array(continuations.values))
        }
        for continuation in targets { continuation.yield(new) }
        return new
    }

    /// The current value first, then every change. The latest value wins when the consumer is slow.
    func updates() -> AsyncStream<HelperStatus> {
        let (stream, continuation) = AsyncStream<HelperStatus>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        let first = lock.withLock { () -> HelperStatus in
            continuations[id] = continuation
            return value
        }
        continuation.yield(first)
        continuation.onTermination = { [weak self] _ in
            self?.lock.withLock { _ = self?.continuations.removeValue(forKey: id) }
        }
        return stream
    }
}

extension HelperStatus.Session {
    init(info: HelperConnectionInfo, connectedAt: Date, subscribedWindows: Int = 0) {
        self.init(
            id: info.sessionID, deviceName: info.deviceName, deviceID: info.deviceID, connectedAt: connectedAt,
            subscribedWindows: subscribedWindows, resumed: info.resumed)
    }
}
#endif
