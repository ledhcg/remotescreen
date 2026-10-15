#if os(macOS)
import Foundation
import LinkProtocol

/// A display, real or virtual, in global Mac points.
public struct StageDisplayID: RawRepresentable, Hashable, Sendable, Codable {
    public var rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
}

public struct StageDisplay: Sendable, Equatable {
    public var id: StageDisplayID
    public var frame: LinkRect
    public var isVirtual: Bool
    public init(id: StageDisplayID, frame: LinkRect, isVirtual: Bool) { self.id = id; self.frame = frame; self.isVirtual = isVirtual }
}

public struct VirtualDisplaySpec: Sendable, Equatable {
    public var name: String
    /// Size in points. With `hiDPI` the backing store is twice as large in each direction.
    public var width: Int
    public var height: Int
    public var hiDPI: Bool
    public var refreshRate: Double
    public init(name: String = "Screon Stage", width: Int, height: Int, hiDPI: Bool = true, refreshRate: Double = 60) {
        self.name = name; self.width = width; self.height = height; self.hiDPI = hiDPI; self.refreshRate = refreshRate
    }
}

public enum StageError: Error, Equatable {
    /// The private virtual display API is missing or refused. The stage falls back to resizing in place.
    case stageUnavailable(String)
    case invalidSpec
    case unknownDisplay
}

/// Virtual display management. The real implementation is `CGVirtualDisplayStage`.
public protocol DisplayStage: Sendable {
    func createDisplay(_ spec: VirtualDisplaySpec) async throws -> StageDisplay
    func removeDisplay(_ id: StageDisplayID) async throws
    /// All active displays, real and virtual.
    func displays() async -> [StageDisplay]
    func frame(of display: StageDisplayID) async -> LinkRect?
}

/// Identifies a window across helper restarts: `WindowID` values are per session, so the persisted journal uses the pid and
/// the window-server number, which stay valid for the lifetime of the window.
public struct StageWindowKey: Hashable, Sendable, Codable {
    public var pid: Int32
    public var windowNumber: UInt32
    public init(pid: Int32, windowNumber: UInt32) { self.pid = pid; self.windowNumber = windowNumber }
}

public struct StageSizeLimits: Sendable, Equatable {
    public var minimum: LinkSize
    public var maximum: LinkSize
    public init(minimum: LinkSize, maximum: LinkSize) { self.minimum = minimum; self.maximum = maximum }
    public static let unbounded = StageSizeLimits(
        minimum: LinkSize(width: 1, height: 1),
        maximum: LinkSize(width: LinkLimits.maxCoordinate, height: LinkLimits.maxCoordinate)
    )
}

/// What the stage needs from the Accessibility layer (implemented with the window tracker). All frames are global points.
///
/// A real implementation toggles `AXEnhancedUserInterface` off around resizes of the owning application and back on after,
/// because with it on, apps animate the change and the read-back is wrong.
public protocol WindowFrameSetter: Sendable {
    /// The window's current frame, or nil if it no longer exists.
    func currentFrame(of window: StageWindowKey) async -> LinkRect?
    /// Moves and resizes, then reads the frame back: the app may have refused or clamped the request. Nil: window gone or failed.
    func setFrame(_ window: StageWindowKey, to rect: LinkRect) async -> LinkRect?
    /// `AXFullScreen = false`.
    func exitFullScreen(_ window: StageWindowKey) async
    /// AX minimum and maximum content size, when known.
    func sizeLimits(of window: StageWindowKey) async -> StageSizeLimits
}

extension WindowFrameSetter {
    public func sizeLimits(of window: StageWindowKey) async -> StageSizeLimits { .unbounded }
}
#endif
