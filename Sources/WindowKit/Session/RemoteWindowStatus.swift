import Foundation
import LinkProtocol

/// Which side has to be updated when the two protocol ranges do not meet.
public enum UpdateTarget: Sendable, Equatable {
    /// This app is too old for the Mac helper.
    case screon
    /// The Mac helper is too old for this app.
    case helper
}

/// Why a connection ended for good (no automatic retry). The app maps its transport error to this.
public enum ConnectionFailureKind: Sendable, Equatable {
    case versionMismatch(UpdateTarget)
    /// The Mac does not know this device (never paired, or removed on the Mac).
    case deviceRevoked
    /// The Mac presented another identity than the one paired.
    case identityChanged
    /// The person at the Mac, or the Mac, refused the connection.
    case denied
    /// Another connection from this device took over.
    case replaced
    /// Out of retries, or the network is gone.
    case connectionLost
}

/// Where the link connection of a computer stands, as far as a window cares.
public enum ConnectionPhase: Sendable, Equatable {
    case connecting
    case connected
    /// Lost; attempt `attempt` of `total` is under way or scheduled.
    case reconnecting(attempt: Int, total: Int)
    case failed(ConnectionFailureKind)
}

/// What the Mac helper last said about itself with `status`. Apply every `status` message in order.
public struct HelperStatus: Sendable, Equatable {
    public private(set) var macLocked = false
    public private(set) var missingPermissions: Set<LinkPermissionKind> = []
    public private(set) var secureInput = false
    public private(set) var stage: LinkStageState?

    public init() {}

    public mutating func apply(_ status: LinkStatus) {
        switch status {
        case .macLocked(let locked): macLocked = locked
        case .permissionMissing(let kind): missingPermissions.insert(kind)
        case .permission(let kind, let state):
            if state == .granted { missingPermissions.remove(kind) } else { missingPermissions.insert(kind) }
        case .stageUnavailable: stage = .unavailable
        case .stage(let state): stage = state
        case .secureInput(let pid): secureInput = true; secureInputPID = pid
        }
    }

    /// The process that holds secure input, when the helper knows it.
    public private(set) var secureInputPID: Int32?

    /// The protocol has no message that says secure input ended, only one that says it is active. The helper repeats it while typing is
    /// being blocked, so the app calls this when no such message has come for a while (and when the connection is renewed).
    public mutating func clearSecureInput() { secureInput = false; secureInputPID = nil }

    /// A new connection: nothing said so far still holds.
    public mutating func reset() { self = HelperStatus() }

    /// The permission to name first, in a fixed order, so the message does not flicker.
    var firstMissingPermission: LinkPermissionKind? {
        let order: [LinkPermissionKind] = [.screenRecording, .accessibility, .inputMonitoring, .automation, .localNetwork]
        return order.first { missingPermissions.contains($0) }
    }
}

/// What a button in the overlay does. The scene decides how; this only names the intent.
public enum RemoteWindowAction: Sendable, Equatable {
    /// Bring the window (or its app) back.
    case reopen
    /// Close this iPad window.
    case close
    /// Open the Mac's whole screen (the Screen Sharing scene) to unlock it.
    case openDesktop
    /// Pair with the Mac again.
    case pairAgain
    /// Try connecting again now.
    case retry

    public var title: String {
        switch self {
        case .reopen: tr("Reopen")
        case .close: tr("Close")
        case .openDesktop: tr("Open the desktop to unlock")
        case .pairAgain: tr("Pair again")
        case .retry: tr("Try again")
        }
    }
}

/// What to show over (or instead of) a remote window.
public enum RemoteWindowOverlay: Sendable, Equatable {
    case connecting
    case reconnecting(attempt: Int, total: Int)
    /// A restored scene is waiting for the helper's snapshot to find its window.
    case lookingForWindow
    case waitingForFirstFrame
    case windowClosed
    case appQuit
    case macLocked
    case permissionMissing(LinkPermissionKind)
    case versionMismatch(UpdateTarget)
    case deviceRevoked
    case identityChanged
    case denied
    case replaced
    case connectionLost

    public var title: String {
        switch self {
        case .connecting: tr("Connecting to the Mac…")
        case .reconnecting(let attempt, let total): tr("Reconnecting (%lld/%lld)…", attempt, total)
        case .lookingForWindow: tr("Looking for this window on the Mac…")
        case .waitingForFirstFrame: tr("Waiting for the first frame…")
        case .windowClosed: tr("This window was closed on the Mac.")
        case .appQuit: tr("The app was quit on the Mac.")
        case .macLocked: tr("The Mac is locked")
        case .permissionMissing: tr("Screon Helper needs permission on the Mac")
        case .versionMismatch: tr("Screon and Screon Helper cannot talk to each other")
        case .deviceRevoked: tr("This device is no longer paired")
        case .identityChanged: tr("This is not the Mac you paired with")
        case .denied: tr("The Mac declined the connection")
        case .replaced: tr("Another connection took over")
        case .connectionLost: tr("Connection lost")
        }
    }

    /// A second line that says what is wrong or what to do, or `nil`.
    public var message: String? {
        switch self {
        case .connecting, .reconnecting, .lookingForWindow, .waitingForFirstFrame: nil
        case .windowClosed: tr("Choose another window from the launcher.")
        case .appQuit: tr("Reopen the app, or choose another window from the launcher.")
        case .macLocked: tr("Windows cannot be shown while the screen is locked. Unlock the Mac from its desktop.")
        case .permissionMissing(let kind): Self.permissionHint(kind)
        case .versionMismatch(let target):
            switch target {
            case .screon: tr("Update Screon on this device.")
            case .helper: tr("Update Screon Helper on the Mac.")
            }
        case .deviceRevoked: tr("The Mac removed this device. Pair it again to continue.")
        case .identityChanged: tr("The Mac's identity changed, or this is another Mac. Pair again only if you trust it.")
        case .denied: tr("The person at the Mac did not allow this device.")
        case .replaced: tr("This device connected from somewhere else. Try again to take the connection back.")
        case .connectionLost: tr("Screon could not reach the Mac.")
        }
    }

    public var actions: [RemoteWindowAction] {
        switch self {
        case .connecting, .reconnecting, .lookingForWindow: [.close]
        case .waitingForFirstFrame, .permissionMissing: []
        case .windowClosed, .appQuit: [.reopen, .close]
        case .macLocked: [.openDesktop]
        case .versionMismatch: [.close]
        case .deviceRevoked, .identityChanged: [.pairAgain, .close]
        case .denied, .replaced, .connectionLost: [.retry, .close]
        }
    }

    /// True when the window's picture is useless or hidden behind the message. A `reconnecting` overlay dims the last frame instead.
    public var coversWindow: Bool {
        switch self {
        case .reconnecting, .waitingForFirstFrame: false
        default: true
        }
    }

    static func permissionHint(_ kind: LinkPermissionKind) -> String {
        switch kind {
        case .screenRecording: tr("Allow Screon Helper to record the screen in System Settings, Privacy & Security.")
        case .accessibility: tr("Allow Screon Helper to control the computer in System Settings, Privacy & Security, Accessibility.")
        case .inputMonitoring: tr("Allow Screon Helper in System Settings, Privacy & Security, Input Monitoring.")
        case .automation: tr("Allow Screon Helper in System Settings, Privacy & Security, Automation.")
        case .localNetwork: tr("Allow Screon Helper to use the local network in System Settings, Privacy & Security.")
        }
    }
}

/// A notice shown over a working window.
public enum RemoteWindowBanner: Sendable, Equatable {
    case secureInput

    public var text: String {
        switch self {
        case .secureInput: tr("Typing is blocked by a password field on the Mac")
        }
    }
}

public struct RemoteWindowPresentation: Sendable, Equatable {
    public var overlay: RemoteWindowOverlay?
    public var banner: RemoteWindowBanner?

    public init(overlay: RemoteWindowOverlay? = nil, banner: RemoteWindowBanner? = nil) {
        self.overlay = overlay
        self.banner = banner
    }
}

public enum RemoteWindowStatus {
    /// Decides what a remote window scene shows. Order of precedence: a failed connection, connecting, reconnecting, a window that
    /// is missing, a locked Mac, a missing permission, no picture yet. A secure-input banner is shown only over a working window.
    public static func present(
        connection: ConnectionPhase,
        binding: SceneBindingState?,
        workspace: RemoteWorkspace,
        helper: HelperStatus,
        hasFrame: Bool
    ) -> RemoteWindowPresentation {
        switch connection {
        case .failed(let kind): return RemoteWindowPresentation(overlay: overlay(for: kind))
        case .connecting: return RemoteWindowPresentation(overlay: .connecting)
        case .reconnecting(let attempt, let total): return RemoteWindowPresentation(overlay: .reconnecting(attempt: attempt, total: total))
        case .connected: break
        }
        guard let binding, workspace.hasSnapshot || binding.windowID != nil else {
            return RemoteWindowPresentation(overlay: .lookingForWindow)
        }
        switch binding {
        case .restoring:
            return RemoteWindowPresentation(overlay: .lookingForWindow)
        case .windowClosed(let hint):
            let appStillRunning = workspace.app(bundleID: hint.bundleID) != nil
                || !workspace.managedWindows(bundleID: hint.bundleID).isEmpty
            return RemoteWindowPresentation(overlay: appStillRunning ? .windowClosed : .appQuit)
        case .bound:
            if helper.macLocked { return RemoteWindowPresentation(overlay: .macLocked) }
            if let kind = helper.firstMissingPermission { return RemoteWindowPresentation(overlay: .permissionMissing(kind)) }
            if !hasFrame { return RemoteWindowPresentation(overlay: .waitingForFirstFrame) }
            return RemoteWindowPresentation(banner: helper.secureInput ? .secureInput : nil)
        }
    }

    static func overlay(for kind: ConnectionFailureKind) -> RemoteWindowOverlay {
        switch kind {
        case .versionMismatch(let target): .versionMismatch(target)
        case .deviceRevoked: .deviceRevoked
        case .identityChanged: .identityChanged
        case .denied: .denied
        case .replaced: .replaced
        case .connectionLost: .connectionLost
        }
    }
}
