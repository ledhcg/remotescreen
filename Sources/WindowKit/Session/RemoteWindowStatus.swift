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
    /// The Mac is reachable only through Tailscale, which is not connected on this device.
    case tailscaleNotConnected
    /// The Mac is reachable only through Tailscale, which the user turned off in Screon.
    case tailscaleTurnedOff
}

/// Where the link connection of a computer stands, as far as a window cares.
public enum ConnectionPhase: Sendable, Equatable {
    case connecting
    case connected
    /// Lost; attempt `attempt` of `total` is under way or scheduled.
    case reconnecting(attempt: Int, total: Int)
    /// The device is offline: no attempt is made (none is used up) until the network is back.
    case waitingForNetwork
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
        case .secureInput(let active, let pid): secureInput = active; secureInputPID = active ? pid : nil
        }
    }

    /// Windows the helper refused to stream, with the reason (`window.subscribeFailed`). Cleared when the window is subscribed again.
    public private(set) var subscribeFailures: [WindowID: LinkSubscribeFailure] = [:]

    /// At most this many remembered; a hostile helper cannot grow the table.
    static let maxSubscribeFailures = 64

    public mutating func noteSubscribeFailure(window: WindowID, reason: LinkSubscribeFailure) {
        if subscribeFailures[window] == nil, subscribeFailures.count >= Self.maxSubscribeFailures { return }
        subscribeFailures[window] = reason
    }

    public mutating func clearSubscribeFailure(window: WindowID) { subscribeFailures[window] = nil }

    /// The process that holds secure input, when the helper knows it.
    public private(set) var secureInputPID: Int32?

    /// Forgets secure input without a helper message (for example when the connection is renewed). The helper normally says when it
    /// ends with `secureInput(active: false, ...)`.
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
    case waitingForNetwork
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
    case tailscaleNotConnected
    case tailscaleTurnedOff

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
        case .waitingForNetwork: tr("No internet connection")
        case .tailscaleNotConnected: tr("Tailscale is not connected")
        case .tailscaleTurnedOff: tr("Tailscale is turned off in Screon")
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
        case .waitingForNetwork: tr("Screon reconnects to the Mac as soon as the network is back.")
        case .tailscaleNotConnected:
            tr("This Mac can only be reached through Tailscale here. Open the Tailscale app and connect: Screon reconnects by itself.")
        case .tailscaleTurnedOff:
            tr("This Mac can only be reached through Tailscale here. Turn on Use Tailscale in Screon's network settings.")
        }
    }

    public var actions: [RemoteWindowAction] {
        switch self {
        case .connecting, .reconnecting, .waitingForNetwork, .lookingForWindow: [.close]
        case .waitingForFirstFrame, .permissionMissing: []
        case .windowClosed, .appQuit: [.reopen, .close]
        case .macLocked: [.openDesktop]
        case .versionMismatch: [.close]
        case .deviceRevoked, .identityChanged: [.pairAgain, .close]
        case .denied, .replaced, .connectionLost, .tailscaleNotConnected, .tailscaleTurnedOff: [.retry, .close]
        }
    }

    /// True when the window's picture is useless or hidden behind the message. A `reconnecting` overlay dims the last frame instead.
    public var coversWindow: Bool {
        switch self {
        case .reconnecting, .waitingForNetwork, .waitingForFirstFrame: false
        default: true
        }
    }

    /// One line per permission the helper reported missing, in a stable order, for the launcher's banner.
    public static func permissionHints(_ helper: HelperStatus) -> [String] {
        helper.missingPermissions.sorted { $0.rawValue < $1.rawValue }.map(permissionHint)
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
    /// The Mac would not stream this window.
    case subscribeFailed(LinkSubscribeFailure)

    public var text: String {
        switch self {
        case .secureInput: tr("Typing is blocked by a password field on the Mac")
        case .subscribeFailed(let reason):
            switch reason {
            case .unknownWindow: tr("The Mac can no longer find this window.")
            case .limit: tr("The Mac is already streaming as many windows as it allows.")
            case .permission: tr("Screon Helper needs permission to record the screen.")
            case .transient: tr("The Mac could not start streaming this window. Trying again may help.")
            }
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
        case .waitingForNetwork: return RemoteWindowPresentation(overlay: .waitingForNetwork)
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
            if !hasFrame {
                // The Mac said no: a spinner would wait for a picture that is not coming.
                if let window = binding.windowID, let reason = helper.subscribeFailures[window] {
                    return RemoteWindowPresentation(banner: .subscribeFailed(reason))
                }
                return RemoteWindowPresentation(overlay: .waitingForFirstFrame)
            }
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
        case .tailscaleNotConnected: .tailscaleNotConnected
        case .tailscaleTurnedOff: .tailscaleTurnedOff
        }
    }
}
