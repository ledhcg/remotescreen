import CoreGraphics
import Testing
@testable import InputKit

@Suite("PencilGesture: chạm, kéo, giữ của Apple Pencil")
struct PencilGestureTests {
    private let a = CGPoint(x: 100, y: 100)

    @Test func aQuickTouchIsALeftClickAtTheTouchPoint() {
        var pencil = PencilGesture()
        _ = pencil.began(at: a, time: 0)
        #expect(pencil.moved(to: CGPoint(x: 102, y: 101), time: 0.05).isEmpty, "xê dịch trong slop: vẫn là chạm")
        #expect(pencil.ended(at: CGPoint(x: 102, y: 101), time: 0.1) == [.click(a)], "nhấp tại điểm đặt bút, không phải điểm nhấc")
    }

    @Test func movingBeyondTheSlopStartsADragFromTheStartPoint() {
        var pencil = PencilGesture()
        _ = pencil.began(at: a, time: 0)
        let b = CGPoint(x: 110, y: 100)
        #expect(pencil.moved(to: b, time: 0.05) == [.press(a), .move(b)])
        let c = CGPoint(x: 150, y: 120)
        #expect(pencil.moved(to: c, time: 0.1) == [.move(c)])
        #expect(pencil.ended(at: c, time: 0.2) == [.move(c), .release(c)])
    }

    @Test func holdingStillIsARightClick() {
        var pencil = PencilGesture()
        _ = pencil.began(at: a, time: 0)
        #expect(pencil.ended(at: a, time: 0.8) == [.rightClick(a)])
    }

    @Test func aLongDragIsNeverARightClick() {
        var pencil = PencilGesture()
        _ = pencil.began(at: a, time: 0)
        _ = pencil.moved(to: CGPoint(x: 200, y: 100), time: 0.1)
        #expect(pencil.ended(at: CGPoint(x: 200, y: 100), time: 2) == [.move(CGPoint(x: 200, y: 100)), .release(CGPoint(x: 200, y: 100))])
    }

    @Test func cancellingReleasesOnlyWhenDragging() {
        var pencil = PencilGesture()
        _ = pencil.began(at: a, time: 0)
        #expect(pencil.cancelled().isEmpty, "hủy một cái chạm: không nhấp")
        _ = pencil.began(at: a, time: 1)
        _ = pencil.moved(to: CGPoint(x: 120, y: 100), time: 1.1)
        #expect(pencil.cancelled() == [.release(CGPoint(x: 120, y: 100))])
        #expect(pencil.ended(at: a, time: 2).isEmpty, "sau khi hủy, lần nhấc lạc không làm gì")
    }
}
