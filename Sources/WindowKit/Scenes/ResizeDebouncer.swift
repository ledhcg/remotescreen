import Foundation
import LinkProtocol

/// Turns the many size changes of an iPad window that is being dragged larger or smaller into one `window.setFrame` once it stops.
///
/// Pure and clock-free: the caller passes the time. The first size seen is the baseline (the scene just opened with the Mac window shown
/// scaled to fit, which must not resize the Mac window); later sizes are sent when they stayed the same for `settleDelay`, the system
/// no longer reports an interactive resize, and they differ from the baseline by more than `tolerance` points.
public struct ResizeDebouncer: Sendable, Equatable {
    public var settleDelay: TimeInterval
    public var tolerance: Double

    private var baseline: LinkSize?
    private var pending: LinkSize?
    private var pendingSince: TimeInterval = 0

    public init(settleDelay: TimeInterval = 0.3, tolerance: Double = 2) {
        self.settleDelay = settleDelay
        self.tolerance = tolerance
    }

    /// A size of the scene in points. Zero, negative and non-finite sizes are ignored.
    public mutating func observe(_ size: LinkSize, at time: TimeInterval) {
        guard size.width.isFinite, size.height.isFinite, size.width >= 1, size.height >= 1 else { return }
        if baseline == nil {
            baseline = size
            return
        }
        if let pending, Self.isClose(pending, size, tolerance: 0.5) { return }
        pending = size
        pendingSince = time
    }

    /// The moment `poll` may first return the pending size, or `nil` when nothing is pending.
    public var deadline: TimeInterval? { pending.map { _ in pendingSince + settleDelay } }

    /// Returns the size to send now, if any. Call at `deadline` and again while `isInteractivelyResizing` stays true.
    public mutating func poll(at time: TimeInterval, isInteractivelyResizing: Bool) -> LinkSize? {
        guard let size = pending, !isInteractivelyResizing, time - pendingSince >= settleDelay else { return nil }
        pending = nil
        if let baseline, Self.isClose(baseline, size, tolerance: tolerance) { return nil }
        baseline = size
        return size
    }

    /// Forget what was sent (for example the Mac changed the window itself); the next size seen becomes the baseline again.
    public mutating func resetBaseline(to size: LinkSize?) {
        baseline = size
        pending = nil
    }

    private static func isClose(_ a: LinkSize, _ b: LinkSize, tolerance: Double) -> Bool {
        abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }
}

/// Size limits for an iPad scene taken from the Mac window's own limits.
public struct SceneSizeLimits: Sendable, Equatable {
    public var minimum: LinkSize
    /// `nil` when the Mac window has no maximum.
    public var maximum: LinkSize?

    /// The smallest scene iPadOS lets a person make is about this big; a Mac window may ask for less, never for more than that floor.
    public static let floor = LinkSize(width: 320, height: 240)

    /// A zero component of `maxSize` means "no maximum" in the protocol. A maximum smaller than the minimum is dropped.
    public init(minSize: LinkSize, maxSize: LinkSize) {
        minimum = LinkSize(
            width: min(max(minSize.width, Self.floor.width), 4096), height: min(max(minSize.height, Self.floor.height), 4096))
        if maxSize.width > 0, maxSize.height > 0, maxSize.width >= minimum.width, maxSize.height >= minimum.height {
            maximum = maxSize
        } else {
            maximum = nil
        }
    }

    /// `size` forced into the limits.
    public func clamp(_ size: LinkSize) -> LinkSize {
        var width = max(size.width, minimum.width), height = max(size.height, minimum.height)
        if let maximum {
            width = min(width, maximum.width)
            height = min(height, maximum.height)
        }
        return LinkSize(width: width, height: height)
    }
}
