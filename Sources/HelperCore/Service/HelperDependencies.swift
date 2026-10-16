#if os(macOS)
import Foundation
import LinkProtocol

/// Settings that are not OS access. Defaults follow docs/app-mode-implementation-plan.md §14.
public struct HelperServiceOptions: Sendable {
    public static let defaultMaxSessions = 4
    public static let defaultMaxSubscriptions = 16

    /// Concurrent iPads. The listener enforces the same limit; the service checks again.
    public var maxSessions = HelperServiceOptions.defaultMaxSessions
    /// Windows one iPad may stream at once (also capped by what the iPad announced in `hello`).
    public var maxSubscriptionsPerSession = HelperServiceOptions.defaultMaxSubscriptions
    /// The virtual stage display created when the first iPad connects. `nil`: no virtual display; windows are still resized in
    /// place and restored.
    public var stageDisplay: VirtualDisplaySpec? = VirtualDisplaySpec(width: 1920, height: 1200)
    /// Per-app audio (needs `HelperDependencies.audio`, the `.audio` capability from the iPad, and this switch). Off by default.
    public var audioEnabled = false
    public var preferredCodec: LinkVideoCodec = .hevc
    /// How often permissions are re-checked (the person may grant one in System Settings while the helper runs).
    public var permissionPollInterval: Duration = .seconds(3)
    /// How often `IsSecureEventInputEnabled` is polled while an iPad is connected.
    public var secureInputPollInterval: Duration = .seconds(1)
    /// How often the Mac pasteboard is checked for something to offer, while an iPad has a window open.
    public var clipboardPollInterval: Duration = .milliseconds(750)
    /// How often the inbox is cleaned of files older than its retention.
    public var inboxCleanupInterval: Duration = .seconds(3600)
    /// Seconds since an arbitrary point, for `RateController`.
    public var clock: @Sendable () -> Double = { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }
    /// Time source for `HelperStatus.Session.connectedAt`.
    public var now: @Sendable () -> Date = { Date() }

    public init() {}
}

/// Audio for one app: capture, and a mapping from the packetizer's PCM packets to what the wire carries.
///
/// The wire protocol only defines Opus (`LinkAudioCodec.opus`) while `AudioPacketizer` produces 16-bit PCM, so audio stays
/// off until a real Opus encoder is supplied as `encode`. (Interface mismatch recorded in the HelperService documentation.)
public struct HelperAudio: Sendable {
    public var capture: any AudioCapturing
    public var codec: LinkAudioCodec
    /// Turns a PCM packet into a wire packet; nil drops it.
    public var encode: @Sendable (LinkAudioPacket) -> LinkAudioPacket?
    public var channels: Int

    public init(
        capture: any AudioCapturing, codec: LinkAudioCodec = .opus, channels: Int = 2,
        encode: @escaping @Sendable (LinkAudioPacket) -> LinkAudioPacket?
    ) {
        self.capture = capture; self.codec = codec; self.channels = channels; self.encode = encode
    }
}

/// Every OS-facing piece, so `HelperService` runs against fakes in tests. `HelperDependencies.live(listener:)` builds the
/// real set for the helper app.
public struct HelperDependencies: Sendable {
    public var listener: any HelperListener
    public var windowSystem: any WindowSystem
    public var workspace: any WorkspaceAccess
    public var installedApps: any InstalledAppSource
    public var recentAppsURL: URL?
    public var captureSystem: any CaptureSystem
    /// Creates the encoder of one window stream.
    public var makeEncoder: @Sendable (EncoderSettings) throws -> any VideoEncoding
    public var eventPoster: any EventPoster
    public var secureInput: any SecureInputProbe
    public var menuSystem: any MenuSystem
    public var pasteboard: any HelperPasteboard
    public var transcoder: any ImageTranscoder
    public var fileOpener: (any FileOpening)?
    public var inboxRoot: URL
    public var displayStage: any DisplayStage
    public var stageJournal: any StageJournalStore
    public var audio: HelperAudio?
    public var lockMonitor: any ScreenLockMonitor
    public var permissions: any PermissionProbe
    public var awake: any DisplayAwakeAssertion

    public init(
        listener: any HelperListener, windowSystem: any WindowSystem, workspace: any WorkspaceAccess,
        installedApps: any InstalledAppSource, recentAppsURL: URL? = nil, captureSystem: any CaptureSystem,
        makeEncoder: @escaping @Sendable (EncoderSettings) throws -> any VideoEncoding, eventPoster: any EventPoster,
        secureInput: any SecureInputProbe, menuSystem: any MenuSystem, pasteboard: any HelperPasteboard,
        transcoder: any ImageTranscoder, fileOpener: (any FileOpening)?, inboxRoot: URL, displayStage: any DisplayStage,
        stageJournal: any StageJournalStore, audio: HelperAudio? = nil, lockMonitor: any ScreenLockMonitor = NeverLockedMonitor(),
        permissions: any PermissionProbe = AlwaysGrantedPermissions(), awake: any DisplayAwakeAssertion = NoopDisplayAwakeAssertion()
    ) {
        self.listener = listener; self.windowSystem = windowSystem; self.workspace = workspace; self.installedApps = installedApps
        self.recentAppsURL = recentAppsURL; self.captureSystem = captureSystem; self.makeEncoder = makeEncoder
        self.eventPoster = eventPoster; self.secureInput = secureInput; self.menuSystem = menuSystem; self.pasteboard = pasteboard
        self.transcoder = transcoder; self.fileOpener = fileOpener; self.inboxRoot = inboxRoot; self.displayStage = displayStage
        self.stageJournal = stageJournal; self.audio = audio; self.lockMonitor = lockMonitor; self.permissions = permissions
        self.awake = awake
    }

    /// The real implementations. `recentAppsURL` and `inboxRoot` default to the helper's Application Support folder.
    public static func live(listener: any HelperListener, audio: HelperAudio? = nil) throws -> HelperDependencies {
        HelperDependencies(
            listener: listener, windowSystem: AXWindowSystem(), workspace: SystemWorkspaceAccess(),
            installedApps: FileManagerAppScanner(), recentAppsURL: nil, captureSystem: ScreenCaptureKitSystem(),
            makeEncoder: { try VTVideoEncoder(settings: $0) }, eventPoster: CGEventPoster(), secureInput: SystemSecureInputProbe(),
            menuSystem: AXMenuSystem(), pasteboard: SystemPasteboard(), transcoder: ImageIOTranscoder(),
            fileOpener: WorkspaceFileOpener(), inboxRoot: try FileInbox.defaultRoot(), displayStage: CGVirtualDisplayStage(),
            stageJournal: FileStageJournalStore(url: try FileStageJournalStore.defaultURL()), audio: audio,
            lockMonitor: CGSessionLockMonitor(), permissions: SystemPermissionProbe(), awake: IOPMDisplayAwakeAssertion())
    }
}
#endif
