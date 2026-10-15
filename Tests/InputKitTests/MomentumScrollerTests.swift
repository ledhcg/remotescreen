import CoreGraphics
import Testing
@testable import InputKit

@Suite("MomentumScroller: quán tính khi cuộn")
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
        #expect(first.y < 0 && second.y < 0, "tiếp tục theo hướng vuốt")
        #expect(abs(second.y) < abs(first.y), "chậm dần")
        #expect(momentum.location == CGPoint(x: 100, y: 200))
    }

    /// Tổng quãng không phụ thuộc nhịp màn hình: 60 Hz hay 120 Hz phải cuộn xa như nhau (tích phân đúng, không cộng xấp xỉ).
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
        #expect(frames < 300, "dừng trong vài giây, không chạy mãi")
        // Giới hạn lý thuyết: v / (−ln d) / 1000 = 800 / 0,002002 / 1000 ≈ 399,6 point.
        #expect(abs(sum - 399.6) < 10, "quãng tổng \(sum)")
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
