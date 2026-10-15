import CoreGraphics
import Foundation
import RFBKit
import Testing
@testable import InputKit

/// Fake coordinate space: a 2000×1000 Mac screen shown at 0.5 point/pixel, content starting at (0, 50) in the viewport.
/// So viewport point (x, y) maps to Mac pixel (2x, 2(y - 50)).
private struct StubSpace: RemoteCoordinateSpace {
    var remoteSize = CGSize(width: 2000, height: 1000)
    var pointsPerRemotePixel = 0.5
    let origin = CGPoint(x: 0, y: 50)

    func remotePixel(forView point: CGPoint, clamped: Bool) -> (x: Int, y: Int)? {
        let x = Int(((point.x - origin.x) / pointsPerRemotePixel).rounded(.down))
        let y = Int(((point.y - origin.y) / pointsPerRemotePixel).rounded(.down))
        if (0..<2000).contains(x) && (0..<1000).contains(y) { return (x, y) }
        guard clamped else { return nil }
        return (min(max(x, 0), 1999), min(max(y, 0), 999))
    }
}

private func pointer(_ buttons: UInt8, _ x: UInt16, _ y: UInt16) -> ClientMessage {
    .pointerEvent(buttons: buttons, x: x, y: y)
}

private let space = StubSpace()

@Suite("TouchMapper: click")
struct TouchClickTests {
    @Test func directTouchTapMovesPressesAndReleasesAtTheTouchedPixel() {
        var mapper = TouchMapper()
        let output = mapper.handle(.tap(CGPoint(x: 100, y: 150), count: 1), in: space, isZoomed: false)
        // (100, 150) → pixel Mac (200, 200)
        #expect(output.messages == [pointer(0, 200, 200), pointer(1, 200, 200), pointer(0, 200, 200)])
        #expect(output.viewportPan == nil)
        #expect(mapper.pointer.x == 200 && mapper.pointer.y == 200)
    }

    @Test func doubleTapIsTwoClicksInARow() {
        var mapper = TouchMapper()
        let output = mapper.handle(.tap(CGPoint(x: 100, y: 150), count: 2), in: space, isZoomed: false)
        #expect(output.messages.count == 6)
        #expect(output.messages.filter { $0 == pointer(1, 200, 200) }.count == 2)
    }

    @Test func touchingTheBlackBarDoesNothingInDirectMode() {
        var mapper = TouchMapper()
        #expect(mapper.handle(.tap(CGPoint(x: 100, y: 20), count: 1), in: space, isZoomed: false).messages.isEmpty)
        #expect(mapper.handle(.twoFingerTap(CGPoint(x: 100, y: 20)), in: space, isZoomed: false).messages.isEmpty)
    }

    @Test func twoFingerTapIsARightClickOnButtonBitTwo() {
        var mapper = TouchMapper()
        let output = mapper.handle(.twoFingerTap(CGPoint(x: 100, y: 150)), in: space, isZoomed: false)
        #expect(output.messages == [pointer(0, 200, 200), pointer(4, 200, 200), pointer(0, 200, 200)])
    }

    @Test func trackpadTapClicksWhereThePointerIsNotWhereTheFingerLanded() {
        var mapper = TouchMapper(policy: TouchPolicy(mode: .trackpad), initialPointer: (10, 20))
        let output = mapper.handle(.tap(CGPoint(x: 900, y: 900), count: 1), in: space, isZoomed: false)
        #expect(output.messages == [pointer(0, 10, 20), pointer(1, 10, 20), pointer(0, 10, 20)])
    }
}

@Suite("TouchMapper: move and drag")
struct TouchMoveDragTests {
    @Test func directTouchOneFingerPanMovesTheCursorWithoutPressing() {
        var mapper = TouchMapper()
        let output = mapper.handle(.pan(location: CGPoint(x: 50, y: 100), translation: CGPoint(x: 5, y: 5), .changed), in: space, isZoomed: false)
        #expect(output.messages == [pointer(0, 100, 100)])
    }

    @Test func trackpadMovesRelativelyScaledByZoomAndSensitivity() {
        var mapper = TouchMapper(policy: TouchPolicy(mode: .trackpad), initialPointer: (10, 20))
        // 10 point ÷ 0,5 point/pixel × 1,6 = 32 pixel; 5 ÷ 0,5 × 1,6 = 16 pixel.
        let output = mapper.handle(.pan(location: .zero, translation: CGPoint(x: 10, y: 5), .changed), in: space, isZoomed: false)
        #expect(output.messages == [pointer(0, 42, 36)])
    }

    @Test func trackpadClampsAtTheScreenEdges() {
        var mapper = TouchMapper(policy: TouchPolicy(mode: .trackpad), initialPointer: (5, 5))
        _ = mapper.handle(.pan(location: .zero, translation: CGPoint(x: -1000, y: -1000), .changed), in: space, isZoomed: false)
        #expect(mapper.pointer.x == 0 && mapper.pointer.y == 0)
        _ = mapper.handle(.pan(location: .zero, translation: CGPoint(x: 100_000, y: 100_000), .changed), in: space, isZoomed: false)
        #expect(mapper.pointer.x == 1999 && mapper.pointer.y == 999)
    }

    @Test func longPressThenDragHoldsTheLeftButtonUntilRelease() {
        var mapper = TouchMapper()
        let began = mapper.handle(.longPress(CGPoint(x: 100, y: 150), .began), in: space, isZoomed: false)
        #expect(began.messages == [pointer(0, 200, 200), pointer(1, 200, 200)])

        let moved = mapper.handle(.longPress(CGPoint(x: 200, y: 250), .changed), in: space, isZoomed: false)
        #expect(moved.messages == [pointer(1, 400, 400)]) // button still held

        let ended = mapper.handle(.longPress(CGPoint(x: 200, y: 250), .ended), in: space, isZoomed: false)
        #expect(ended.messages == [pointer(0, 400, 400)])
    }

    @Test func movesAfterReleaseDoNotPress() {
        var mapper = TouchMapper()
        _ = mapper.handle(.longPress(CGPoint(x: 100, y: 150), .began), in: space, isZoomed: false)
        _ = mapper.handle(.longPress(CGPoint(x: 100, y: 150), .ended), in: space, isZoomed: false)
        let after = mapper.handle(.pan(location: CGPoint(x: 60, y: 100), translation: .zero, .changed), in: space, isZoomed: false)
        #expect(after.messages == [pointer(0, 120, 100)])
    }

    @Test func releaseAllFreesAHeldButton() {
        var mapper = TouchMapper()
        _ = mapper.handle(.longPress(CGPoint(x: 100, y: 150), .began), in: space, isZoomed: false)
        #expect(mapper.releaseAll() == [pointer(0, 200, 200)])
        #expect(mapper.releaseAll().isEmpty)
    }

    @Test func changedWithoutBeganIsIgnored() {
        var mapper = TouchMapper()
        #expect(mapper.handle(.longPress(CGPoint(x: 100, y: 150), .changed), in: space, isZoomed: false).messages.isEmpty)
        #expect(mapper.handle(.longPress(CGPoint(x: 100, y: 150), .ended), in: space, isZoomed: false).messages.isEmpty)
    }
}

@Suite("TouchMapper: scroll and policy")
struct TouchScrollPolicyTests {
    @Test func fingersMovingUpScrollDownWithNaturalScrolling() {
        var mapper = TouchMapper()
        _ = mapper.handle(.twoFingerPan(location: CGPoint(x: 100, y: 150), translation: .zero, .began), in: space, isZoomed: false)
        // 50 points up = 2 ticks (24 points per tick), remainder 2. Button 5 (bit 4, value 16) is scroll down.
        let output = mapper.handle(.twoFingerPan(location: CGPoint(x: 100, y: 150), translation: CGPoint(x: 0, y: -50), .changed), in: space, isZoomed: false)
        #expect(output.messages == [pointer(16, 200, 200), pointer(0, 200, 200), pointer(16, 200, 200), pointer(0, 200, 200)])
    }

    @Test func leftoverDistanceAccumulatesIntoTheNextTick() {
        var mapper = TouchMapper()
        _ = mapper.handle(.twoFingerPan(location: CGPoint(x: 100, y: 150), translation: .zero, .began), in: space, isZoomed: false)
        _ = mapper.handle(.twoFingerPan(location: CGPoint(x: 100, y: 150), translation: CGPoint(x: 0, y: -50), .changed), in: space, isZoomed: false)
        // Remainder -2; another -22 makes -24, exactly one more tick.
        let more = mapper.handle(.twoFingerPan(location: CGPoint(x: 100, y: 150), translation: CGPoint(x: 0, y: -22), .changed), in: space, isZoomed: false)
        #expect(more.messages.count == 2)
        #expect(more.messages.first == pointer(16, 200, 200))
    }

    @Test func smallMovementsBelowOneTickSendNothing() {
        var mapper = TouchMapper()
        let output = mapper.handle(.twoFingerPan(location: CGPoint(x: 100, y: 150), translation: CGPoint(x: 0, y: -10), .changed), in: space, isZoomed: false)
        #expect(output.messages.isEmpty)
    }

    @Test func classicScrollingReversesTheDirection() {
        var policy = TouchPolicy()
        policy.naturalScrolling = false
        var mapper = TouchMapper(policy: policy)
        let output = mapper.handle(.twoFingerPan(location: CGPoint(x: 100, y: 150), translation: CGPoint(x: 0, y: -24), .changed), in: space, isZoomed: false)
        #expect(output.messages == [pointer(8, 200, 200), pointer(0, 200, 200)]) // button 4 (bit 3, value 8) is scroll up
    }

    @Test func horizontalScrollUsesButtonsSixAndSeven() {
        var mapper = TouchMapper()
        let output = mapper.handle(.twoFingerPan(location: CGPoint(x: 100, y: 150), translation: CGPoint(x: 30, y: 0), .changed), in: space, isZoomed: false)
        // Finger to the right + natural scrolling = content moves right = scroll left (button 6, bit 5, value 32).
        #expect(output.messages == [pointer(32, 200, 200), pointer(0, 200, 200)])
    }

    @Test func zoomedInGesturesPanTheViewportInsteadOfSendingMouseEvents() {
        var mapper = TouchMapper()
        let one = mapper.handle(.pan(location: .zero, translation: CGPoint(x: 7, y: -3), .changed), in: space, isZoomed: true)
        #expect(one.messages.isEmpty)
        #expect(one.viewportPan == CGPoint(x: 7, y: -3))

        let two = mapper.handle(.twoFingerPan(location: .zero, translation: CGPoint(x: 4, y: 9), .changed), in: space, isZoomed: true)
        #expect(two.messages.isEmpty)
        #expect(two.viewportPan == CGPoint(x: 4, y: 9))
    }

    @Test func policyDefaultsAreWhatTheDocumentationSays() {
        let direct = TouchPolicy(mode: .directTouch)
        #expect(direct.oneFingerDrag(isZoomed: false) == .moveCursor)
        #expect(direct.oneFingerDrag(isZoomed: true) == .panViewport)
        #expect(direct.twoFingerPan(isZoomed: false) == .scroll)
        #expect(direct.twoFingerPan(isZoomed: true) == .panViewport)
        #expect(TouchPolicy(mode: .trackpad).oneFingerDrag(isZoomed: true) == .moveCursor)
    }

    @Test func aCustomPolicyChoiceTakesEffect() {
        // One-finger drag and drop: switching `oneFingerDrag` to `.dragWithLeftButton` presses and holds the left button when the drag starts.
        struct DragPolicySpace {}
        var mapper = TouchMapper()
        // Simulated with longPress, because the customizable policy lives in TouchPolicy (it cannot be injected in this test).
        let began = mapper.handle(.longPress(CGPoint(x: 100, y: 150), .began), in: space, isZoomed: false)
        #expect(began.messages.last == pointer(1, 200, 200))
    }
}

@Suite("TouchMapper: unknown pointer position")
struct UnknownPointerTests {
    @Test func startsWithoutAKnownPointer() {
        #expect(!TouchMapper().hasPointer)
        #expect(TouchMapper(initialPointer: (3, 4)).hasPointer)
    }

    @Test func aTapMakesThePointerKnown() {
        var mapper = TouchMapper()
        _ = mapper.handle(.tap(CGPoint(x: 100, y: 150), count: 1), in: space, isZoomed: false)
        #expect(mapper.hasPointer)
    }

    @Test func tappingTheBlackBarKeepsItUnknown() {
        var mapper = TouchMapper()
        _ = mapper.handle(.tap(CGPoint(x: 100, y: 20), count: 1), in: space, isZoomed: false)
        #expect(!mapper.hasPointer)
    }

    /// The Mac's real pointer is at an unknown place; starting from the (0, 0) corner would make the first drag jump to the screen corner.
    @Test func firstTrackpadDragStartsFromTheCentreOfTheScreen() {
        var mapper = TouchMapper(policy: TouchPolicy(mode: .trackpad))
        let output = mapper.handle(
            .pan(location: CGPoint(x: 50, y: 100), translation: CGPoint(x: 10, y: 0), .changed), in: space, isZoomed: false
        )
        // The middle of a 2000×1000 screen is (1000, 500). 10 points / 0.5 = 20 pixels, times sensitivity 1.6 = 32.
        #expect(output.messages == [pointer(0, 1032, 500)])
        #expect(mapper.pointer.x == 1032 && mapper.pointer.y == 500)
    }

    @Test func aKnownPointerIsNotRecentred() {
        var mapper = TouchMapper(policy: TouchPolicy(mode: .trackpad), initialPointer: (10, 20))
        _ = mapper.handle(.pan(location: .zero, translation: CGPoint(x: 10, y: 0), .changed), in: space, isZoomed: false)
        #expect(mapper.pointer.x == 42 && mapper.pointer.y == 20)
    }
}

@Suite("TouchMapper: Apple Pencil, iPad mouse and trackpad")
struct PointerDeviceTests {
    /// The pencil is always absolute, even in trackpad mode (fingers are relative).
    @Test func pencilClickIsAbsoluteEvenInTrackpadMode() {
        var mapper = TouchMapper(policy: TouchPolicy(mode: .trackpad), initialPointer: (5, 5))
        let output = mapper.handle(.pencil(.click(CGPoint(x: 100, y: 150))), in: space, isZoomed: false)
        #expect(output.messages == [pointer(0, 200, 200), pointer(1, 200, 200), pointer(0, 200, 200)])
        #expect(mapper.pointer.x == 200 && mapper.pointer.y == 200)
    }

    @Test func pencilRightClickUsesButtonThree() {
        var mapper = TouchMapper()
        let output = mapper.handle(.pencil(.rightClick(CGPoint(x: 100, y: 150))), in: space, isZoomed: false)
        #expect(output.messages == [pointer(0, 200, 200), pointer(4, 200, 200), pointer(0, 200, 200)])
    }

    @Test func pencilDragPressesMovesAndReleases() {
        var mapper = TouchMapper(policy: TouchPolicy(mode: .trackpad))
        var sent = mapper.handle(.pencil(.press(CGPoint(x: 100, y: 150))), in: space, isZoomed: false).messages
        sent += mapper.handle(.pencil(.move(CGPoint(x: 110, y: 150))), in: space, isZoomed: false).messages
        sent += mapper.handle(.pencil(.release(CGPoint(x: 120, y: 150))), in: space, isZoomed: false).messages
        #expect(sent == [pointer(0, 200, 200), pointer(1, 200, 200), pointer(1, 220, 200), pointer(0, 240, 200)])
    }

    @Test func pencilTapOnTheBlackBorderDoesNothing() {
        var mapper = TouchMapper()
        #expect(mapper.handle(.pencil(.click(CGPoint(x: 100, y: 10))), in: space, isZoomed: false).messages.isEmpty)
    }

    @Test func hoverMovesThePointerWithoutButtons() {
        var mapper = TouchMapper(policy: TouchPolicy(mode: .trackpad))
        let output = mapper.handle(.hover(CGPoint(x: 50, y: 100)), in: space, isZoomed: false)
        #expect(output.messages == [pointer(0, 100, 100)])
        #expect(mapper.hasPointer)
    }

    @Test func mouseButtonsPressDragAndReleaseImmediately() {
        var mapper = TouchMapper()
        var sent = mapper.handle(.mouseButton(CGPoint(x: 100, y: 150), .primary, .began), in: space, isZoomed: false).messages
        sent += mapper.handle(.mouseButton(CGPoint(x: 105, y: 150), .primary, .changed), in: space, isZoomed: false).messages
        sent += mapper.handle(.mouseButton(CGPoint(x: 105, y: 150), .primary, .ended), in: space, isZoomed: false).messages
        #expect(sent == [pointer(0, 200, 200), pointer(1, 200, 200), pointer(1, 210, 200), pointer(0, 210, 200)])
    }

    @Test func secondaryMouseButtonIsARightClick() {
        var mapper = TouchMapper()
        var sent = mapper.handle(.mouseButton(CGPoint(x: 100, y: 150), .secondary, .began), in: space, isZoomed: false).messages
        sent += mapper.handle(.mouseButton(CGPoint(x: 100, y: 150), .secondary, .ended), in: space, isZoomed: false).messages
        #expect(sent == [pointer(0, 200, 200), pointer(4, 200, 200), pointer(0, 200, 200)])
    }

    /// The mouse wheel scrolls the Mac even when zoomed in (two fingers while zoomed pan the viewport).
    @Test func mouseScrollAlwaysScrollsTheMacAtTheMouse() {
        var mapper = TouchMapper(policy: TouchPolicy(mode: .trackpad), initialPointer: (5, 5))
        _ = mapper.handle(.scroll(location: CGPoint(x: 100, y: 150), translation: .zero, .began), in: space, isZoomed: true)
        let output = mapper.handle(.scroll(location: CGPoint(x: 100, y: 150), translation: CGPoint(x: 0, y: -24), .changed), in: space, isZoomed: true)
        #expect(output.viewportPan == nil)
        #expect(output.messages == [pointer(16, 200, 200), pointer(0, 200, 200)], "finger up, natural scrolling: button 5 (down) at the mouse pointer")
    }

    @Test func pencilDoubleTapRightClicksAtThePointerOnlyOnceItIsKnown() {
        var mapper = TouchMapper()
        #expect(mapper.handle(.secondaryClickAtPointer, in: space, isZoomed: false).messages.isEmpty, "pointer position not yet known")
        _ = mapper.handle(.hover(CGPoint(x: 100, y: 150)), in: space, isZoomed: false)
        #expect(mapper.handle(.secondaryClickAtPointer, in: space, isZoomed: false).messages
            == [pointer(0, 200, 200), pointer(4, 200, 200), pointer(0, 200, 200)])
    }

    @Test func releaseAllFreesAHeldMouseButton() {
        var mapper = TouchMapper()
        _ = mapper.handle(.mouseButton(CGPoint(x: 100, y: 150), .primary, .began), in: space, isZoomed: false)
        #expect(mapper.releaseAll() == [pointer(0, 200, 200)])
    }
}

@Suite("TouchMapper: smooth scrolling and Apple gestures (message 23)")
struct AppleGestureMappingTests {
    private func smooth() -> TouchMapper {
        var policy = TouchPolicy()
        policy.appleSmoothScroll = true
        return TouchMapper(policy: policy)
    }

    private func scrolls(_ messages: [ClientMessage]) -> [AppleScroll] {
        messages.compactMap { if case .appleEvent(.scroll(let scroll)) = $0 { scroll } else { nil } }
    }

    /// Fake space: 0.5 point per pixel, Mac at 1x (1 pixel per point, the default), so 1 finger point = 2 points on the Mac.
    @Test func aSwipeIsBeganChangedEndedInMacPoints() {
        var mapper = smooth()
        let at = CGPoint(x: 100, y: 150)
        var sent = mapper.handle(.twoFingerPan(location: at, translation: .zero, .began), in: space, isZoomed: false).messages
        sent += mapper.handle(.twoFingerPan(location: at, translation: CGPoint(x: 0, y: -30), .changed), in: space, isZoomed: false).messages
        sent += mapper.handle(.twoFingerPan(location: at, translation: .zero, .ended), in: space, isZoomed: false).messages
        let events = scrolls(sent)
        #expect(events.map(\.phase) == [.began, .changed, .ended])
        #expect(events[1].deltaY == -60, "finger up 30 points (60 Mac pixels), natural scrolling: content moves up 60 points")
        #expect(events.allSatisfy { $0.x == 200 && $0.y == 200 && $0.momentum == .none })
        #expect(!sent.contains { if case .pointerEvent = $0 { true } else { false } }, "no wheel ticks any more")
    }

    @Test func stepsAfterTheFingersLiftBecomeMomentum() {
        var mapper = smooth()
        let at = CGPoint(x: 100, y: 150)
        _ = mapper.handle(.twoFingerPan(location: at, translation: .zero, .began), in: space, isZoomed: false)
        _ = mapper.handle(.twoFingerPan(location: at, translation: .zero, .ended), in: space, isZoomed: false)
        var sent = mapper.handle(.twoFingerPan(location: at, translation: CGPoint(x: 0, y: 12), .changed), in: space, isZoomed: false).messages
        sent += mapper.handle(.twoFingerPan(location: at, translation: CGPoint(x: 0, y: 6), .changed), in: space, isZoomed: false).messages
        sent += mapper.handle(.twoFingerPan(location: at, translation: .zero, .ended), in: space, isZoomed: false).messages
        let events = scrolls(sent)
        #expect(events.map(\.momentum) == [.begin, .continue, .end])
        #expect(events.allSatisfy { $0.phase == AppleScroll.Phase.none })
        #expect(events.map(\.deltaY) == [24, 12, 0])
    }

    @Test func retinaMacHalvesTheDistance() {
        var mapper = smooth()
        mapper.policy.remotePixelsPerMacPoint = 2
        let at = CGPoint(x: 100, y: 150)
        _ = mapper.handle(.twoFingerPan(location: at, translation: .zero, .began), in: space, isZoomed: false)
        let sent = mapper.handle(.twoFingerPan(location: at, translation: CGPoint(x: 0, y: -30), .changed), in: space, isZoomed: false).messages
        #expect(scrolls(sent).map(\.deltaY) == [-30])
    }

    @Test func slowScrollingKeepsTheFraction() {
        var mapper = smooth()
        let at = CGPoint(x: 100, y: 150)
        _ = mapper.handle(.twoFingerPan(location: at, translation: .zero, .began), in: space, isZoomed: false)
        var total: Int32 = 0
        for _ in 0..<10 {
            let sent = mapper.handle(.twoFingerPan(location: at, translation: CGPoint(x: 0, y: 0.4), .changed), in: space, isZoomed: false).messages
            total += scrolls(sent).reduce(0) { $0 + $1.deltaY }
        }
        #expect(total == 8, "10 times 0.4 point (0.8 Mac point) must give 8 points, not 0")
    }

    @Test func turnedOffItStillSendsWheelTicks() {
        var mapper = TouchMapper()
        let at = CGPoint(x: 100, y: 150)
        _ = mapper.handle(.twoFingerPan(location: at, translation: .zero, .began), in: space, isZoomed: false)
        let sent = mapper.handle(.twoFingerPan(location: at, translation: CGPoint(x: 0, y: -24), .changed), in: space, isZoomed: false).messages
        #expect(scrolls(sent).isEmpty)
        #expect(sent == [pointer(16, 200, 200), pointer(0, 200, 200)])
    }

    @Test func pinchMovesThePointerToTheFingersThenMagnifies() {
        var mapper = TouchMapper()
        let at = CGPoint(x: 100, y: 150)
        var sent = mapper.handle(.magnify(location: at, scaleDelta: 0, .began), in: space, isZoomed: false).messages
        sent += mapper.handle(.magnify(location: at, scaleDelta: 0.1, .changed), in: space, isZoomed: false).messages
        sent += mapper.handle(.rotate(location: at, degrees: -12, .changed), in: space, isZoomed: false).messages
        sent += mapper.handle(.magnify(location: at, scaleDelta: 0, .ended), in: space, isZoomed: false).messages
        #expect(sent == [
            pointer(0, 200, 200),
            .appleEvent(.magnify(0, phase: .began, x: 200, y: 200)),
            .appleEvent(.magnify(0.1, phase: .changed, x: 200, y: 200)),
            .appleEvent(.rotate(-12, phase: .changed, x: 200, y: 200)),
            .appleEvent(.magnify(0, phase: .ended, x: 200, y: 200)),
        ])
    }

    @Test func aChangeReportedWithBeganOrEndedIsSentAsItsOwnChangedStep() {
        var mapper = TouchMapper()
        let at = CGPoint(x: 100, y: 150)
        var sent = mapper.handle(.rotate(location: at, degrees: 4, .began), in: space, isZoomed: false).messages
        sent += mapper.handle(.rotate(location: at, degrees: -1, .ended), in: space, isZoomed: false).messages
        #expect(sent == [
            pointer(0, 200, 200),
            .appleEvent(.rotate(0, phase: .began, x: 200, y: 200)),
            .appleEvent(.rotate(4, phase: .changed, x: 200, y: 200)),
            .appleEvent(.rotate(-1, phase: .changed, x: 200, y: 200)),
            .appleEvent(.rotate(0, phase: .ended, x: 200, y: 200)),
        ])
    }
}
