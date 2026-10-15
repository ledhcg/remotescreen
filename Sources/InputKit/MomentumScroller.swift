import CoreGraphics
import Foundation

/// Momentum after lifting two scrolling fingers, like the Mac trackpad and `UIScrollView`: keeps scrolling at the release velocity, slowing
/// exponentially, and stops when slow enough or when the user touches again. Pure math: the view calls `advance` every display tick and feeds the
/// returned distance into the existing scroll path (wheel ticks, or panning the viewport when zoomed).
public struct MomentumScroller: Sendable, Equatable {
    /// Decay factor per millisecond, equal to `UIScrollView.DecelerationRate.normal` (0.998): after 1 second about 13% of the velocity remains.
    public static let decayPerMillisecond = 0.998
    /// Releasing slower than this (points/second) gives no momentum: that is a stop, not a flick.
    public static let startSpeed = 200.0
    /// Stops when slower than this.
    public static let stopSpeed = 20.0

    public private(set) var velocity = CGPoint.zero
    /// Position of the two fingers at release (to scroll at exactly that spot in direct-touch mode).
    public private(set) var location = CGPoint.zero
    public private(set) var isActive = false

    public init() {}

    /// Starts momentum if the flick is fast enough. Returns `true` if it started.
    @discardableResult
    public mutating func start(velocity: CGPoint, at location: CGPoint) -> Bool {
        guard hypot(velocity.x, velocity.y) >= Self.startSpeed else {
            stop()
            return false
        }
        self.velocity = velocity
        self.location = location
        isActive = true
        return true
    }

    public mutating func stop() {
        isActive = false
        velocity = .zero
    }

    /// Distance travelled in `seconds` seconds since the last call (the exact integral of the exponentially decaying velocity, so the result does not
    /// depend on a 60 or 120 Hz display). Returns `.zero` and stops itself when slow enough.
    public mutating func advance(by seconds: Double) -> CGPoint {
        guard isActive, seconds > 0 else { return .zero }
        let milliseconds = seconds * 1000
        let factor = pow(Self.decayPerMillisecond, milliseconds)
        // ∫ v·d^t dt from 0 to T (t in ms) = v·(d^T − 1)/ln(d), converting ms → s.
        let distanceFactor = (factor - 1) / log(Self.decayPerMillisecond) / 1000
        let travelled = CGPoint(x: velocity.x * distanceFactor, y: velocity.y * distanceFactor)
        velocity = CGPoint(x: velocity.x * factor, y: velocity.y * factor)
        if hypot(velocity.x, velocity.y) < Self.stopSpeed { isActive = false }
        return travelled
    }
}
