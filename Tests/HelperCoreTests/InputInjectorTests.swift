#if os(macOS)
import Foundation
import LinkProtocol
import Testing
@testable import HelperCore

@Suite(.timeLimit(.minutes(2))) struct InputInjectorTests {
    let poster = RecordingPoster()
    let geometry = FakeGeometry()
    let focuser = FakeFocuser()
    let secure = FakeSecureInput()
    let log = EventLog()
    let clock = ManualClock()
    let window: WindowID = 7
    let injector: InputInjector

    init() {
        let log = self.log
        let clock = self.clock
        injector = InputInjector(
            poster: poster, geometry: geometry, focuser: focuser, secureInput: secure, authorizedWindows: [7],
            now: { clock.now() }, onEvent: { log.add($0) }
        )
        geometry.set(window, LinkRect(x: 100, y: 200, width: 400, height: 300))
        focuser.setFrontmost([window])
    }

    private func pointer(_ x: Double, _ y: Double, _ buttons: LinkMouseButtons = [], window: WindowID? = nil,
                         pressure: Float? = nil, tilt: LinkTilt? = nil) -> LinkMessage {
        .inputPointer(LinkPointerEvent(window: window ?? self.window, point: LinkPoint(x: x, y: y), buttons: buttons,
                                       modifiers: [], pressure: pressure, tilt: tilt))
    }

    // MARK: Coordinates

    @Test func resolvesWindowRelativeToGlobal() async {
        await injector.handle(pointer(10, 20))
        #expect(poster.events == [.mouseMove(at: LinkPoint(x: 110, y: 220), modifiers: [], pen: nil)])
    }

    @Test func usesTheFrameAtInjectionTimeNotAtCreationTime() async {
        await injector.handle(pointer(10, 10))
        // The window moves on the Mac, then a later event for the same relative point arrives.
        geometry.set(window, LinkRect(x: 600, y: 50, width: 400, height: 300))
        await injector.handle(pointer(10, 10))
        #expect(poster.events == [
            .mouseMove(at: LinkPoint(x: 110, y: 210), modifiers: [], pen: nil),
            .mouseMove(at: LinkPoint(x: 610, y: 60), modifiers: [], pen: nil),
        ])
    }

    @Test func windowMovingWhileTheEventWaitsForTheFocuserIsReResolved() async {
        focuser.setFrontmost([])
        let geometry = self.geometry
        let window = self.window
        // The first lookup happens before the raise; the move happens during the raise, so the second lookup sees it.
        geometry.onNextLookup { }
        geometry.onNextLookup { geometry.set(window, LinkRect(x: 0, y: 0, width: 400, height: 300)) }
        await injector.handle(pointer(5, 5, .left))
        #expect(poster.events.contains(.mouseDown(button: .left, at: LinkPoint(x: 5, y: 5), clickCount: 1, modifiers: [], pen: nil)))
    }

    @Test func unknownWindowIsDropped() async {
        await injector.handle(pointer(1, 1, window: 99))
        await injector.handle(pointer(1, 1, .left, window: 99))
        await injector.handle(.inputScroll(LinkScrollEvent(window: 99, dx: 0, dy: 5, phase: .changed, momentumPhase: .none, continuous: true)))
        #expect(poster.events.isEmpty)
        #expect(focuser.raised.isEmpty)
    }

    @Test func destroyedWindowIsDropped() async {
        geometry.set(window, nil)
        await injector.handle(pointer(1, 1))
        #expect(poster.events.isEmpty)
    }

    @Test func emptyFrameIsDropped() async {
        geometry.set(window, LinkRect(x: 0, y: 0, width: 0, height: 0))
        await injector.handle(pointer(0, 0))
        #expect(poster.events.isEmpty)
    }

    @Test func clampsToTheWindowRect() async {
        await injector.handle(pointer(-50, 9999))
        await injector.handle(pointer(9999, -50))
        #expect(poster.events == [
            .mouseMove(at: LinkPoint(x: 100, y: 500), modifiers: [], pen: nil),
            .mouseMove(at: LinkPoint(x: 500, y: 200), modifiers: [], pen: nil),
        ])
    }

    @Test func nonFinitePointsAreDropped() async {
        await injector.handle(pointer(.nan, 1))
        await injector.handle(pointer(1, .infinity))
        await injector.handle(pointer(2_000_000, 1))
        #expect(poster.events.isEmpty)
    }

    // MARK: Buttons

    @Test func pressDragRelease() async {
        await injector.handle(pointer(10, 10, .left))
        await injector.handle(pointer(20, 20, .left))
        await injector.handle(pointer(30, 30, []))
        #expect(poster.events == [
            .mouseMove(at: LinkPoint(x: 110, y: 210), modifiers: [], pen: nil),
            .mouseDown(button: .left, at: LinkPoint(x: 110, y: 210), clickCount: 1, modifiers: [], pen: nil),
            .mouseDrag(button: .left, at: LinkPoint(x: 120, y: 220), modifiers: [], pen: nil),
            .mouseUp(button: .left, at: LinkPoint(x: 130, y: 230), clickCount: 1, modifiers: [], pen: nil),
        ])
        #expect(await injector.pressedButtons.isEmpty)
    }

    @Test func doubleClickIncrementsTheClickCount() async {
        for _ in 0..<2 {
            await injector.handle(pointer(10, 10, .left))
            await injector.handle(pointer(10, 10, []))
            clock.advance(.milliseconds(100))
        }
        let downs = poster.events.compactMap { event -> Int? in
            if case .mouseDown(_, _, let count, _, _) = event { return count }
            return nil
        }
        #expect(downs == [1, 2])
    }

    @Test func slowSecondClickStartsOver() async {
        await injector.handle(pointer(10, 10, .left))
        await injector.handle(pointer(10, 10, []))
        clock.advance(.seconds(2))
        await injector.handle(pointer(10, 10, .left))
        let downs = poster.events.compactMap { event -> Int? in
            if case .mouseDown(_, _, let count, _, _) = event { return count }
            return nil
        }
        #expect(downs == [1, 1])
    }

    @Test func releaseStillGoesThroughWhenTheWindowDisappearedMidDrag() async {
        await injector.handle(pointer(10, 10, .left))
        geometry.set(window, nil)
        await injector.handle(pointer(10, 10, []))
        #expect(poster.events.last == .mouseUp(button: .left, at: LinkPoint(x: 110, y: 210), clickCount: 1, modifiers: [], pen: nil))
        #expect(await injector.pressedButtons.isEmpty)
    }

    // MARK: Focus follows interaction

    @Test func raisesTheWindowBeforeAPressWhenItIsNotFrontmost() async {
        focuser.setFrontmost([])
        await injector.handle(pointer(10, 10, .left))
        #expect(focuser.raised == [window])
    }

    @Test func doesNotRaiseAFrontmostWindow() async {
        await injector.handle(pointer(10, 10, .left))
        #expect(focuser.raised.isEmpty)
    }

    @Test func doesNotRaiseForHoverOrDragOrRelease() async {
        focuser.setFrontmost([])
        await injector.handle(pointer(10, 10))
        #expect(focuser.raised.isEmpty)
        await injector.handle(pointer(10, 10, .left))
        #expect(focuser.raised == [window])
        await injector.handle(pointer(12, 12, .left))
        await injector.handle(pointer(12, 12, []))
        #expect(focuser.raised == [window])
    }

    @Test func coalescesRepeatedRaisesOfTheSameWindow() async {
        focuser.setFrontmost([])
        await injector.handle(pointer(10, 10, .left))
        await injector.handle(pointer(10, 10, []))
        clock.advance(.milliseconds(50))
        await injector.handle(pointer(12, 10, .left))
        #expect(focuser.raised == [window])
        clock.advance(.seconds(1))
        await injector.handle(pointer(12, 10, []))
        focuser.setFrontmost([])
        await injector.handle(pointer(12, 10, .left))
        #expect(focuser.raised == [window, window])
    }

    // MARK: Pen

    @Test func penEntersAndLeavesProximity() async {
        await injector.handle(pointer(10, 10, [], pressure: 0))
        await injector.handle(pointer(10, 10, .left, pressure: 0.5, tilt: LinkTilt(x: .pi / 4, y: -2)))
        await injector.handle(pointer(10, 10, []))
        let kinds = poster.events
        #expect(kinds.first == .tabletProximity(entering: true, at: LinkPoint(x: 110, y: 210)))
        #expect(kinds.contains(.mouseDown(button: .left, at: LinkPoint(x: 110, y: 210), clickCount: 1, modifiers: [],
                                          pen: PenState(pressure: 0.5, tiltX: 0.5, tiltY: -1))))
        #expect(kinds.last == .tabletProximity(entering: false, at: LinkPoint(x: 110, y: 210)))
    }

    // MARK: Scroll and gestures

    @Test func scrollTargetsTheLastPointerPositionInThatWindow() async {
        await injector.handle(pointer(40, 50))
        poster.clear()
        await injector.handle(.inputScroll(LinkScrollEvent(window: window, dx: 1, dy: -8, phase: .began, momentumPhase: .none, continuous: true)))
        #expect(poster.events == [.scroll(at: LinkPoint(x: 140, y: 250), dx: 1, dy: -8, continuous: true, phase: .began, momentumPhase: .none, modifiers: [])])
    }

    @Test func scrollWithoutAPointerStartsAtTheCentreAndMovesTheCursorThere() async {
        await injector.handle(.inputScroll(LinkScrollEvent(window: window, dx: 0, dy: 3, phase: .changed, momentumPhase: .changed, continuous: true)))
        #expect(poster.events.first == .mouseMove(at: LinkPoint(x: 300, y: 350), modifiers: [], pen: nil))
        #expect(poster.events.count == 2)
    }

    @Test func gesturePostedWhenSupportedAndFallsBackToCommandScrollOtherwise() async {
        await injector.handle(.inputGesture(LinkGestureEvent(window: window, kind: .magnify, value: 0.5, phase: .changed)))
        #expect(poster.events.contains(.gesture(kind: .magnify, phase: .changed, value: 0.5, at: LinkPoint(x: 300, y: 350))))

        poster.supportsGestures = false
        poster.clear()
        await injector.handle(.inputGesture(LinkGestureEvent(window: window, kind: .magnify, value: 0.5, phase: .changed)))
        #expect(poster.events == [.scroll(at: LinkPoint(x: 300, y: 350), dx: 0, dy: 5, continuous: false, phase: .none, momentumPhase: .none, modifiers: .command)])

        poster.clear()
        await injector.handle(.inputGesture(LinkGestureEvent(window: window, kind: .rotate, value: 5, phase: .changed)))
        #expect(poster.events.isEmpty)
    }

    // MARK: Keys and text

    @Test func keysAreTrackedAndReleasedOnDisconnect() async {
        await injector.setKeyboardWindow(window); focuser.front = window
        await injector.handle(.inputKey(LinkKeyEvent(keycode: 55, down: true, modifiers: .command)))
        await injector.handle(.inputKey(LinkKeyEvent(keycode: 8, down: true, modifiers: .command)))
        await injector.handle(pointer(10, 10, .left))
        await injector.handle(pointer(20, 10, .left))
        #expect(await injector.pressedKeycodes == [55, 8])
        poster.clear()

        await injector.releaseAll()
        #expect(poster.events == [
            .mouseUp(button: .left, at: LinkPoint(x: 120, y: 210), clickCount: 1, modifiers: [], pen: nil),
            .key(keycode: 8, down: false, modifiers: []),
            .key(keycode: 55, down: false, modifiers: []),
        ])
        #expect(await injector.pressedKeycodes.isEmpty)
        #expect(await injector.pressedButtons.isEmpty)

        poster.clear()
        await injector.releaseAll()
        #expect(poster.events.isEmpty)
    }

    @Test func endingOneSessionReleasesOnlyItsOwnInput() async {
        await injector.setKeyboardWindow(window); focuser.front = window
        await injector.handle(.inputKey(LinkKeyEvent(keycode: 55, down: true, modifiers: .command)), session: 1)
        await injector.handle(.inputKey(LinkKeyEvent(keycode: 8, down: true, modifiers: .command)), session: 2)
        await injector.handle(pointer(10, 10, .left), session: 2)
        #expect(await injector.pressedKeycodes(session: 1) == [55])
        #expect(await injector.pressedKeycodes(session: 2) == [8])
        poster.clear()

        await injector.releaseAll(session: 1)
        #expect(poster.events == [.key(keycode: 55, down: false, modifiers: [])])
        #expect(await injector.pressedKeycodes == [8])
        #expect(await injector.pressedButtons == .left)

        poster.clear()
        await injector.releaseAll(session: 2)
        #expect(poster.events.contains(.key(keycode: 8, down: false, modifiers: [])))
        #expect(poster.events.contains { if case .mouseUp = $0 { true } else { false } })
        #expect(await injector.pressedKeycodes.isEmpty)
        #expect(await injector.pressedButtons.isEmpty)
    }

    @Test func aKeyBothSessionsHoldStaysDownUntilTheLastReleases() async {
        await injector.setKeyboardWindow(window); focuser.front = window
        await injector.handle(.inputKey(LinkKeyEvent(keycode: 56, down: true, modifiers: .shift)), session: 1)
        await injector.handle(.inputKey(LinkKeyEvent(keycode: 56, down: true, modifiers: .shift)), session: 2)
        poster.clear()
        await injector.releaseAll(session: 1)
        #expect(poster.events.isEmpty)
        await injector.releaseAll(session: 2)
        #expect(poster.events == [.key(keycode: 56, down: false, modifiers: [])])
    }

    @Test func releaseAllLeavesStylusProximityAndCancelsGestures() async {
        await injector.handle(pointer(10, 10, .left, pressure: 0.3))
        await injector.handle(.inputGesture(LinkGestureEvent(window: window, kind: .magnify, value: 0.1, phase: .began)))
        poster.clear()
        await injector.releaseAll()
        #expect(poster.events.contains(.gesture(kind: .magnify, phase: .cancelled, value: 0, at: LinkPoint(x: 110, y: 210))))
        #expect(poster.events.contains(.tabletProximity(entering: false, at: LinkPoint(x: 110, y: 210))))
    }

    @Test func releasedKeyIsForgotten() async {
        await injector.setKeyboardWindow(window); focuser.front = window
        await injector.handle(.inputKey(LinkKeyEvent(keycode: 0, down: true, modifiers: [])))
        await injector.handle(.inputKey(LinkKeyEvent(keycode: 0, down: false, modifiers: [])))
        #expect(await injector.pressedKeycodes.isEmpty)
    }

    @Test func keyWithoutMacKeycodeUsesTheKeysymTable() async {
        await injector.setKeyboardWindow(window); focuser.front = window
        await injector.handle(.inputKey(LinkKeyEvent(keycode: LinkKeyEvent.noKeycode, keysym: 0x61, down: true, modifiers: [])))
        await injector.handle(.inputKey(LinkKeyEvent(keycode: LinkKeyEvent.noKeycode, keysym: 0x61, down: false, modifiers: [])))
        await injector.handle(.inputKey(LinkKeyEvent(keycode: LinkKeyEvent.noKeycode, keysym: 0x41, down: true, modifiers: [])))
        await injector.handle(.inputKey(LinkKeyEvent(keycode: LinkKeyEvent.noKeycode, keysym: 0x41, down: false, modifiers: [])))
        await injector.handle(.inputKey(LinkKeyEvent(keycode: LinkKeyEvent.noKeycode, keysym: 0xFF0D, down: true, modifiers: [])))
        #expect(poster.events == [
            .key(keycode: 0, down: true, modifiers: []),
            .key(keycode: 0, down: false, modifiers: []),
            .key(keycode: 0, down: true, modifiers: .shift),
            .key(keycode: 0, down: false, modifiers: .shift),
            .key(keycode: 36, down: true, modifiers: []),
        ])
    }

    @Test func printableKeysymWithoutAKeyUsesUnicodeTextAndUnknownOnesAreDropped() async {
        await injector.setKeyboardWindow(window); focuser.front = window
        await injector.handle(.inputKey(LinkKeyEvent(keycode: LinkKeyEvent.noKeycode, keysym: 0x0100_1EA1, down: true, modifiers: [])))  // ạ
        await injector.handle(.inputKey(LinkKeyEvent(keycode: LinkKeyEvent.noKeycode, keysym: 0x0100_1EA1, down: false, modifiers: [])))
        #expect(poster.events == [.unicode("ạ")])
        poster.clear()
        for keysym: UInt32? in [0xFE50, 0xFFFFFF, 0x0000, 0x1F, nil] {
            await injector.handle(.inputKey(LinkKeyEvent(keycode: LinkKeyEvent.noKeycode, keysym: keysym, down: true, modifiers: [])))
        }
        #expect(poster.events.isEmpty)
        #expect(await injector.pressedKeycodes.isEmpty)
    }

    @Test func textIsPostedInChunks() async {
        await injector.setKeyboardWindow(window); focuser.front = window
        await injector.handle(.inputText(String(repeating: "a", count: 45)))
        #expect(poster.events == [
            .unicode(String(repeating: "a", count: 20)), .unicode(String(repeating: "a", count: 20)), .unicode("aaaaa"),
        ])
    }

    @Test func oversizedTextIsDropped() async {
        await injector.handle(.inputText(String(repeating: "a", count: LinkLimits.maxTextInputBytes + 1)))
        #expect(poster.events.isEmpty)
    }

    @Test func nonInputMessagesAreIgnored() async {
        await injector.handle(.ping(timestampMicros: 1))
        #expect(poster.events.isEmpty)
    }

    // MARK: Status

    @Test func secureInputChangeIsReportedOnceEachWay() async {
        await injector.setKeyboardWindow(window); focuser.front = window
        secure.enabled = true
        await injector.handle(.inputKey(LinkKeyEvent(keycode: 0, down: true, modifiers: [])))
        await injector.handle(.inputKey(LinkKeyEvent(keycode: 0, down: false, modifiers: [])))
        secure.enabled = false
        await injector.pollSecureInput()
        #expect(log.events == [.secureInputChanged(true), .secureInputChanged(false)])
    }

    @Test func missingPostAccessIsReportedOnceAndNothingIsPosted() async {
        poster.canPostEvents = false
        await injector.handle(pointer(1, 1))
        await injector.handle(pointer(2, 2))
        #expect(poster.events.isEmpty)
        #expect(log.events == [.postingNotPermitted])
    }

    @Test func eventsAreProcessedInArrivalOrderEvenWhenFocusingSuspends() async {
        focuser.setFrontmost([])
        let injector = self.injector
        let down = pointer(10, 10, .left)
        let up = pointer(10, 10, [])
        // The press must be inside the injector (suspended while focusing) before the release arrives; two `async let`s
        // would not guarantee which one reaches the actor first.
        let first = Task { await injector.handle(down) }
        while focuser.raised.isEmpty { await Task.yield() }
        await injector.handle(up)
        await first.value
        let kinds = poster.events.map { event -> String in
            switch event {
            case .mouseDown: "down"
            case .mouseUp: "up"
            default: "other"
            }
        }.filter { $0 != "other" }
        #expect(kinds == ["down", "up"])
    }

    // MARK: Authorization

    @Test func inputForAnUnauthorizedWindowIsDropped() async {
        let other: WindowID = 8
        geometry.set(other, LinkRect(x: 0, y: 0, width: 100, height: 100))
        await injector.handle(pointer(1, 1, window: other))
        await injector.handle(pointer(1, 1, .left, window: other))
        await injector.handle(.inputScroll(LinkScrollEvent(window: other, dx: 0, dy: 5, phase: .changed, momentumPhase: .none, continuous: true)))
        await injector.handle(.inputGesture(LinkGestureEvent(window: other, kind: .magnify, value: 1, phase: .changed)))
        #expect(poster.events.isEmpty)
        #expect(focuser.raised.isEmpty)
    }

    @Test func nothingIsAuthorizedByDefault() async {
        let bare = InputInjector(poster: poster, geometry: geometry, focuser: focuser, secureInput: secure)
        await bare.handle(pointer(1, 1))
        await bare.handle(.inputKey(LinkKeyEvent(keycode: 1, down: true, modifiers: [])))
        await bare.handle(.inputText("x"))
        #expect(poster.events.isEmpty)
    }

    @Test func releaseIsStillDeliveredAfterDeauthorization() async {
        await injector.handle(pointer(10, 10, .left))
        await injector.handle(.inputKey(LinkKeyEvent(keycode: 5, down: true, modifiers: [])))
        await injector.setAuthorizedWindows([])
        poster.clear()
        await injector.handle(pointer(10, 10, []))
        await injector.handle(.inputKey(LinkKeyEvent(keycode: 5, down: false, modifiers: [])))
        #expect(poster.events == [
            .mouseUp(button: .left, at: LinkPoint(x: 110, y: 210), clickCount: 1, modifiers: [], pen: nil),
            .key(keycode: 5, down: false, modifiers: []),
        ])
        #expect(await injector.pressedButtons.isEmpty)
        #expect(await injector.pressedKeycodes.isEmpty)
    }

    @Test func pressesAfterDeauthorizationAreDropped() async {
        await injector.setAuthorizedWindows([])
        await injector.handle(pointer(10, 10, .left))
        #expect(poster.events.isEmpty)
    }

    @Test func keysAndTextAreDroppedWithoutAKeyboardWindow() async {
        await injector.handle(.inputKey(LinkKeyEvent(keycode: 1, down: true, modifiers: [])))
        await injector.handle(.inputText("hi"))
        #expect(poster.events.isEmpty)
        // De-authorizing the keyboard window forgets it.
        await injector.setKeyboardWindow(window)
        focuser.front = window
        await injector.setAuthorizedWindows([])
        await injector.handle(.inputText("hi"))
        #expect(poster.events.isEmpty)
    }

    @Test func aPressMakesItsWindowTheKeyboardWindow() async {
        await injector.handle(pointer(10, 10, .left))
        await injector.handle(pointer(10, 10, []))
        focuser.front = window
        poster.clear()
        await injector.handle(.inputText("a"))
        #expect(poster.events == [.unicode("a")])
    }

    @Test func keysRefocusTheKeyboardWindowWhenAnotherAppIsFrontmost() async {
        await injector.setKeyboardWindow(window)
        focuser.front = 99 // a terminal the iPad is not showing
        await injector.handle(.inputKey(LinkKeyEvent(keycode: 1, down: true, modifiers: [])))
        #expect(focuser.raised == [window])
        #expect(poster.events == [.key(keycode: 1, down: true, modifiers: [])])
    }

    @Test func keysDoNotRaiseWhenAnAuthorizedWindowIsAlreadyFrontmost() async {
        await injector.setKeyboardWindow(window)
        focuser.front = window
        await injector.handle(.inputKey(LinkKeyEvent(keycode: 1, down: true, modifiers: [])))
        #expect(focuser.raised.isEmpty)
    }

    @Test func textIsNotPostedWhenRefocusFails() async {
        await injector.setKeyboardWindow(window)
        focuser.front = 99
        focuser.refuseRaise = true
        await injector.handle(.inputText("secret"))
        await injector.handle(.inputKey(LinkKeyEvent(keycode: 1, down: true, modifiers: [])))
        #expect(poster.events.isEmpty)
        #expect(await injector.pressedKeycodes.isEmpty)
        // A key-up for a key this session never pressed is dropped.
        await injector.handle(.inputKey(LinkKeyEvent(keycode: 1, down: false, modifiers: [])))
        #expect(poster.events.isEmpty)
    }

    // MARK: Topmost verification

    @Test func keyUpForAKeyNeverPressedIsDropped() async {
        await injector.handle(.inputKey(LinkKeyEvent(keycode: 9, down: false, modifiers: .command)))
        #expect(poster.events.isEmpty)
    }

    @Test func keyUpUsesTheModifiersRecordedAtKeyDown() async {
        await injector.setKeyboardWindow(window)
        focuser.front = window
        await injector.handle(.inputKey(LinkKeyEvent(keycode: 9, down: true, modifiers: .shift)))
        await injector.handle(.inputKey(LinkKeyEvent(keycode: 9, down: false, modifiers: [.command, .control])))
        await injector.handle(.inputKey(LinkKeyEvent(keycode: 9, down: false, modifiers: [])))
        #expect(poster.events == [
            .key(keycode: 9, down: true, modifiers: .shift),
            .key(keycode: 9, down: false, modifiers: .shift),
        ])
    }

    @Test func pressIsDroppedWhenAnotherWindowCoversThePoint() async {
        focuser.setFrontmost([])
        focuser.refuseRaise = true
        await injector.handle(pointer(10, 10, .left))
        #expect(poster.events.isEmpty)
        #expect(await injector.pressedButtons.isEmpty)
    }

    @Test func coalescingNeverSkipsTheTopmostCheck() async {
        focuser.setFrontmost([])
        await injector.handle(pointer(10, 10, .left))
        await injector.handle(pointer(10, 10, []))
        poster.clear()
        // Within the coalesce interval the raise is skipped, but another window now covers the point.
        focuser.setFrontmost([])
        focuser.refuseRaise = true
        clock.advance(.milliseconds(50))
        await injector.handle(pointer(10, 10, .left))
        #expect(poster.events.isEmpty)
        #expect(focuser.raised == [window])
    }

    @Test func dragAndReleaseContinueAfterAVerifiedPress() async {
        await injector.handle(pointer(10, 10, .left))
        focuser.setFrontmost([]) // something floats over the window mid-drag
        await injector.handle(pointer(30, 30, .left))
        await injector.handle(pointer(30, 30, []))
        let kinds = poster.events.map { event -> String in
            switch event {
            case .mouseDown: "down"
            case .mouseDrag: "drag"
            case .mouseUp: "up"
            default: "other"
            }
        }
        #expect(kinds == ["other", "down", "drag", "up"])
    }

    @Test func hoverNeedsNoTopmostCheckButStaysClamped() async {
        focuser.setFrontmost([])
        await injector.handle(pointer(-500, 9999))
        #expect(poster.events == [.mouseMove(at: LinkPoint(x: 100, y: 500), modifiers: [], pen: nil)])
        #expect(focuser.raised.isEmpty)
    }

    @Test func scrollAndGestureAreDroppedWhenTheWindowIsNotTopmost() async {
        focuser.setFrontmost([])
        await injector.handle(.inputScroll(LinkScrollEvent(window: window, dx: 0, dy: 5, phase: .changed, momentumPhase: .none, continuous: true)))
        await injector.handle(.inputGesture(LinkGestureEvent(window: window, kind: .magnify, value: 1, phase: .changed)))
        #expect(poster.events.isEmpty)
        #expect(focuser.raised.isEmpty)
    }
}

@Suite(.timeLimit(.minutes(2))) struct TextChunkerTests {
    private func units(_ chunks: [String]) -> [Int] { chunks.map { $0.utf16.count } }

    @Test func emptyTextHasNoChunks() { #expect(TextChunker.chunks("").isEmpty) }

    @Test func shortTextIsOneChunk() { #expect(TextChunker.chunks("hello") == ["hello"]) }

    @Test func chunksNeverExceedTheLimitAndRejoinToTheOriginal() {
        let samples = [
            String(repeating: "x", count: 100),
            String(repeating: "😀", count: 30),
            String(repeating: "Tiếng Việt có dấu, ", count: 8),
            String(repeating: "日本語の文章です。", count: 9),
            "👨‍👩‍👧‍👦 family 🇻🇳 flag 👍🏽 tone",
        ]
        for sample in samples {
            let chunks = TextChunker.chunks(sample)
            #expect(chunks.joined() == sample)
            #expect(units(chunks).allSatisfy { $0 <= 20 && $0 > 0 })
        }
    }

    @Test func surrogatePairsAreNeverSplit() {
        // 19 units of ASCII, then an emoji (2 units): it cannot fit in the first chunk.
        let text = String(repeating: "a", count: 19) + "😀" + "b"
        let chunks = TextChunker.chunks(text)
        #expect(chunks == [String(repeating: "a", count: 19), "😀b"])
        for chunk in chunks { #expect(String(decoding: Array(chunk.utf16), as: UTF16.self) == chunk) }
    }

    @Test func graphemeClustersStayTogether() {
        // A decomposed Vietnamese letter: base + two combining marks.
        let letter = "e\u{0302}\u{0301}"
        let text = String(repeating: "a", count: 18) + letter
        let chunks = TextChunker.chunks(text)
        #expect(chunks == [String(repeating: "a", count: 18), letter])
    }

    @Test func aHugeClusterIsSplitBetweenScalarsButNotInsideAPair() {
        let cluster = "a" + String(repeating: "\u{0301}", count: 30)
        let chunks = TextChunker.chunks(cluster)
        #expect(chunks.joined() == cluster)
        #expect(units(chunks).allSatisfy { $0 <= 20 })

        let emojiCluster = "😀" + String(repeating: "\u{1F3FD}", count: 12)
        let emojiChunks = TextChunker.chunks(emojiCluster)
        #expect(emojiChunks.joined() == emojiCluster)
        #expect(units(emojiChunks).allSatisfy { $0 <= 20 && $0 % 2 == 0 })
    }

    @Test func flagsAndZeroWidthJoinerSequencesFitWholeWhenPossible() {
        let family = "👨‍👩‍👧‍👦" // 11 UTF-16 units
        let chunks = TextChunker.chunks(family + family)
        #expect(chunks == [family, family])
    }
}
#endif
