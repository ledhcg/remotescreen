import Foundation

/// Optional features a peer supports, exchanged in `hello` and `welcome`. The usable set is the intersection.
/// Unknown bits from a newer peer are kept in `rawValue` and simply never used.
public struct LinkCapabilities: OptionSet, Sendable, Hashable {
    public let rawValue: UInt64
    public init(rawValue: UInt64) { self.rawValue = rawValue }

    /// Helper can arrange windows on a stage (virtual display or reserved region).
    public static let stage = LinkCapabilities(rawValue: 1 << 0)
    /// Magnify, rotate and swipe gestures.
    public static let gestures = LinkCapabilities(rawValue: 1 << 1)
    /// Pressure and tilt from Apple Pencil.
    public static let tablet = LinkCapabilities(rawValue: 1 << 2)
    public static let audio = LinkCapabilities(rawValue: 1 << 3)
    /// Clipboard types beyond plain text.
    public static let clipboardRich = LinkCapabilities(rawValue: 1 << 4)
    public static let files = LinkCapabilities(rawValue: 1 << 5)
    public static let menus = LinkCapabilities(rawValue: 1 << 6)
    /// Long-term reference frames (`video.ack`, `video.lost`).
    public static let ltr = LinkCapabilities(rawValue: 1 << 7)
    /// 10-bit HEVC (Main 10).
    public static let main10 = LinkCapabilities(rawValue: 1 << 8)
    public static let hevc = LinkCapabilities(rawValue: 1 << 9)
    public static let h264 = LinkCapabilities(rawValue: 1 << 10)
    /// Popup surfaces sent as images (`surface.snapshot`).
    public static let surfaces = LinkCapabilities(rawValue: 1 << 11)
    public static let cursorShapes = LinkCapabilities(rawValue: 1 << 12)
}

/// Outcome of comparing two protocol version ranges.
public enum LinkNegotiationResult: Sendable, Equatable {
    /// Both sides speak this version (the highest one they share).
    case agreed(UInt16)
    /// The remote's newest version is older than our oldest. The remote needs an update.
    case remoteTooOld(remoteMax: UInt16)
    /// The remote's oldest version is newer than our newest. This side needs an update.
    case remoteTooNew(remoteMin: UInt16)
}

/// Version negotiation. `hello` travels inside the authenticated channel and is echoed in the pairing transcript, so a
/// man in the middle cannot force an older version than both sides support.
public enum LinkVersionNegotiation {
    /// The highest version in both ranges, or `nil` when they do not overlap.
    public static func negotiate(local: ClosedRange<UInt16>, remote: ClosedRange<UInt16>) -> UInt16? {
        let low = max(local.lowerBound, remote.lowerBound)
        let high = min(local.upperBound, remote.upperBound)
        return low <= high ? high : nil
    }

    /// Like `negotiate`, but says which side is out of date when there is no overlap.
    public static func evaluate(local: ClosedRange<UInt16>, remote: ClosedRange<UInt16>) -> LinkNegotiationResult {
        if let version = negotiate(local: local, remote: remote) { return .agreed(version) }
        return remote.upperBound < local.lowerBound ? .remoteTooOld(remoteMax: remote.upperBound) : .remoteTooNew(remoteMin: remote.lowerBound)
    }

    /// Features both sides support.
    public static func negotiate(local: LinkCapabilities, remote: LinkCapabilities) -> LinkCapabilities {
        local.intersection(remote)
    }
}

/// Protocol versions of this build.
public enum LinkProtocolVersion {
    /// The newest version this build speaks.
    public static let current: UInt16 = 1
    /// The range this build accepts.
    public static let supported: ClosedRange<UInt16> = 1...current
}
