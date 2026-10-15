import CoreGraphics
import Testing
@testable import InputKit

@Suite("MomentumScroller: scroll momentum")
struct MomentumScrollerTests {
    @Test func aSlowReleaseHasNoMomentum() {
        var momentum = MomentumScroller()
        let started = momentum.start(velocity: CGPoint(x: 0, y: 150), at: .zero)
        #expect(!started)
        #expect(!momentum.isActive)
        let moved = momentum.advance(by: 1.0 / 60)
        #expect(moved == .zero)
    }

    @Test func aFlickCoastsInTheSameDirectionAndSlowsDown() {
        var momentum = MomentumScroller()
        let started = momentum.start(velocity: CGPoint(x: 0, y: -1500), at: CGPoint(x: 100, y: 200))
        #expect(started)
        let first = momentum.advance(by: 1.0 / 60)
        let second = momentum.advance(by: 1.0 / 60)
        #expect(first.y < 0 && second.y < 0, "continues in the swipe direction")
        #expect(abs(second.y) < abs(first.y), "slows down")
        #expect(momentum.location == CGPoint(x: 100, y: 200))
    }

    /// The total distance does not depend on the display rate: 60 Hz and 120 Hz must scroll equally far (exact integral, not an approximate sum).
    @Test func distanceDoesNotDependOnTheDisplayRate() {
        func total(_ hz: Double) -> Double {
            var momentum = MomentumScroller()
            momentum.start(velocity: CGPoint(x: 0, y: 2000), at: .zero)
            var sum = 0.0
            while momentum.isActive { sum += momentum.advance(by: 1 / hz).y }
            return sum
        }
        #expect(abs(total(60) - total(120)) < 2, "60 Hz: \(total(60)), 120 Hz: \(total(120))")
    }

    @Test func itStopsByItselfAndTheTotalIsFinite() {
        var momentum = MomentumScroller()
        momentum.start(velocity: CGPoint(x: 800, y: 0), at: .zero)
        var frames = 0, sum = 0.0
        while momentum.isActive, frames < 10_000 { sum += momentum.advance(by: 1.0 / 60).x; frames += 1 }
        #expect(!momentum.isActive)
        #expect(frames < 300, "stops within a few seconds, does not run forever")
        // Theoretical limit: v / (−ln d) / 1000 = 800 / 0.002002 / 1000 ≈ 399.6 points.
        #expect(abs(sum - 399.6) < 10, "total distance \(sum)")
    }

    @Test func stopCancelsImmediately() {
        var momentum = MomentumScroller()
        momentum.start(velocity: CGPoint(x: 0, y: 3000), at: .zero)
        momentum.stop()
        #expect(!momentum.isActive)
        let moved = momentum.advance(by: 1.0 / 60)
        #expect(moved == .zero)
    }
}
