#if os(macOS)
import Foundation
import LinkProtocol

/// Handle of one accessibility window element. Stable while the window exists; the system implementation owns the mapping.
public struct AXWindowToken: Hashable, Sendable {
    public var pid: Int32
    public var id: UInt64
    public init(pid: Int32, id: UInt64) { self.pid = pid; self.id = id }
}

/// One entry of `CGWindowListCopyWindowInfo`. `bounds` are in global points (top-left origin).
public struct CGWindowRecord: Sendable, Equatable {
    public var id: UInt32
    public var pid: Int32
    public var bounds: LinkRect
    public var layer: Int
    public var alpha: Double
    public var isOnScreen: Bool
    /// Only present with the Screen Recording permission.
    public var name: String?
    public init(id: UInt32, pid: Int32, bounds: LinkRect, layer: Int, alpha: Double = 1, isOnScreen: Bool = true, name: String? = nil) {
        self.id = id; self.pid = pid; self.bounds = bounds; self.layer = layer; self.alpha = alpha; self.isOnScreen = isOnScreen; self.name = name
    }
}

/// The accessibility attributes of one window, read in one go.
public struct AXWindowState: Sendable, Equatable {
    public var token: AXWindowToken
    /// From `_AXUIElementGetWindow` when it is available.
    public var cgWindowID: UInt32?
    public var title: String
    public var frame: LinkRect
    public var role: String
    public var subrole: String
    public var isMinimised: Bool
    public var isFullScreen: Bool
    public var isMain: Bool
    public var isFocused: Bool
    public var isModal: Bool
    public init(
        token: AXWindowToken, cgWindowID: UInt32? = nil, title: String = "", frame: LinkRect, role: String = "AXWindow",
        subrole: String = "AXStandardWindow", isMinimised: Bool = false, isFullScreen: Bool = false, isMain: Bool = false,
        isFocused: Bool = false, isModal: Bool = false
    ) {
        self.token = token; self.cgWindowID = cgWindowID; self.title = title; self.frame = frame; self.role = role; self.subrole = subrole
        self.isMinimised = isMinimised; self.isFullScreen = isFullScreen; self.isMain = isMain; self.isFocused = isFocused; self.isModal = isModal
    }
}

public enum WindowSystemError: Error, Sendable, Equatable {
    /// The app did not answer within the messaging timeout (0.5 s).
    case timeout
    /// Accessibility permission is missing.
    case permissionDenied
    /// The element no longer exists.
    case windowGone
    case unsupported
    case failed(Int32)
}

/// The accessibility notifications the tracker listens to (design §2.3).
public enum AXNotificationKind: Sendable, Equatable, CaseIterable {
    case windowCreated, windowDestroyed, windowMoved, windowResized, windowMiniaturized, windowDeminiaturized
    case titleChanged, focusedWindowChanged, appActivated, appDeactivated, sheetCreated, menuOpened, menuClosed
}

public enum WindowSystemEvent: Sendable, Equatable {
    case appLaunched(pid: Int32)
    case appTerminated(pid: Int32)
    case ax(pid: Int32, AXNotificationKind)
}

/// All window-related OS calls behind one seam. The real implementation is `AXWindowSystem`; tests script a fake.
public protocol WindowSystem: Sendable {
    // MARK: Process level, no permission needed
    /// Pids of the apps whose windows are tracked (regular activation policy).
    func trackablePIDs() -> [Int32]
    func bundleID(forPID pid: Int32) -> String?
    func frontmostPID() -> Int32?
    /// Window list across all Spaces, front to back.
    func cgWindows() -> [CGWindowRecord]
    func backingScale(for frame: LinkRect) -> Double

    // MARK: Accessibility reads
    func axWindows(pid: Int32) async throws -> [AXWindowState]
    func axWindow(_ token: AXWindowToken) async throws -> AXWindowState

    // MARK: Accessibility writes
    func setPosition(_ token: AXWindowToken, to point: LinkPoint) async throws
    func setSize(_ token: AXWindowToken, to size: LinkSize) async throws
    func raise(_ token: AXWindowToken) async throws
    func setMinimised(_ token: AXWindowToken, _ minimised: Bool) async throws
    func setFullScreen(_ token: AXWindowToken, _ fullScreen: Bool) async throws
    func pressClose(_ token: AXWindowToken) async throws
    func pressZoom(_ token: AXWindowToken) async throws

    // MARK: Application attributes
    /// `AXEnhancedUserInterface`; `nil` when the app does not have it.
    func enhancedUI(pid: Int32) async throws -> Bool?
    func setEnhancedUI(pid: Int32, _ enabled: Bool) async throws
    /// `AXManualAccessibility` (wakes up Electron and Chromium accessibility trees).
    func manualAccessibility(pid: Int32) async throws -> Bool?
    func setManualAccessibility(pid: Int32, _ enabled: Bool) async throws

    // MARK: Notifications
    func startObserving(pid: Int32) async throws
    func stopObserving(pid: Int32) async
    /// App launch/termination and accessibility notifications. One stream per call.
    func events() -> AsyncStream<WindowSystemEvent>
}
#endif
