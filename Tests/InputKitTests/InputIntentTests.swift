import CoreGraphics
import Foundation
import RFBKit
import Testing
@testable import InputKit

private let encoder = RFBInputEncoder()
private let origin = RemotePoint(x: 10, y: 20)

private func pointer(_ buttons: UInt8, _ x: UInt16, _ y: UInt16) -> ClientMessage { .pointerEvent(buttons: buttons, x: x, y: y) }

@Suite("RFBInputEncoder")
struct RFBInputEncoderTests {
    @Test func pointerRoundsAndClampsToSixteenBits() {
        let cases: [(RemotePoint, UInt16, UInt16)] = [
            (RemotePoint(x: 10.4, y: 20.6), 10, 21),
            (RemotePoint(x: -5, y: -0.4), 0, 0),
            (RemotePoint(x: 70000, y: 65535.4), 65535, 65535),
            (RemotePoint(x: .nan, y: -.infinity), 0, 0),
            (RemotePoint(x: .infinity, y: 1e300), 65535, 65535),
        ]
        for (point, x, y) in cases {
            #expect(encoder.encode(.pointer(at: point, buttons: [], modifiers: nil)) == [pointer(0, x, y)], "\(point)")
        }
    }

    @Test func pointerButtonsUseTheRFBMaskBitsAndIgnoreModifiers() {
        let both: PointerButtons = [.left, .right]
        #expect(encoder.encode(.pointer(at: origin, buttons: both, modifiers: [.command])) == [pointer(5, 10, 20)])
        #expect(encoder.encode(.pointer(at: origin, buttons: .middle, modifiers: nil)) == [pointer(2, 10, 20)])
    }

    @Test func lineScrollBecomesWheelTicksKeepingHeldButtons() {
        func scroll(dx: Double, dy: Double, buttons: PointerButtons = []) -> [ClientMessage] {
            encoder.encode(.scroll(at: origin, buttons: buttons, dx: dx, dy: dy, phase: .none, momentumPhase: .none, isContinuous: false))
        }
        // Positive dy: content moves down = scroll up = wheel button 4 (bit 3). Negative: button 5 (bit 4).
        #expect(scroll(dx: 0, dy: 2) == [pointer(8, 10, 20), pointer(0, 10, 20), pointer(8, 10, 20), pointer(0, 10, 20)])
        #expect(scroll(dx: 0, dy: -1) == [pointer(16, 10, 20), pointer(0, 10, 20)])
        // Horizontal: positive dx moves content right = scroll left (button 6, bit 5); negative is button 7 (bit 6).
        #expect(scroll(dx: 1, dy: 0) == [pointer(32, 10, 20), pointer(0, 10, 20)])
        #expect(scroll(dx: -1, dy: 0) == [pointer(64, 10, 20), pointer(0, 10, 20)])
        // Vertical ticks come first, and a held button stays in the mask.
        #expect(scroll(dx: 1, dy: 1, buttons: .left) == [pointer(9, 10, 20), pointer(1, 10, 20), pointer(33, 10, 20), pointer(1, 10, 20)])
        #expect(scroll(dx: 0, dy: 0).isEmpty)
        #expect(scroll(dx: .nan, dy: .infinity).isEmpty)
    }

    @Test func continuousScrollBecomesAnAppleScrollEvent() {
        let sent = encoder.encode(.scroll(at: origin, buttons: [], dx: 3, dy: -4, phase: .changed, momentumPhase: .none, isContinuous: true))
        #expect(sent == [.appleEvent(.scroll(AppleScroll(deltaX: 3, deltaY: -4, phase: .changed, momentum: .none, x: 10, y: 20)))])
        let momentum = encoder.encode(.scroll(at: origin, buttons: [], dx: 0, dy: 1, phase: .none, momentumPhase: .changed, isContinuous: true))
        #expect(momentum == [.appleEvent(.scroll(AppleScroll(deltaX: 0, deltaY: 1, phase: .none, momentum: .continue, x: 10, y: 20)))])
        let huge = encoder.encode(.scroll(at: origin, buttons: [], dx: 1e15, dy: -.infinity, phase: .changed, momentumPhase: .none, isContinuous: true))
        #expect(huge == [.appleEvent(.scroll(AppleScroll(deltaX: .max, deltaY: .min, phase: .changed, momentum: .none, x: 10, y: 20)))])
    }

    @Test func gesturesMapToPinchAndRotateAndSmartZoomHasNoRFBForm() {
        #expect(encoder.encode(.gesture(kind: .magnify, at: origin, value: 0.1, phase: .changed))
            == [.appleEvent(.magnify(0.1, phase: .changed, x: 10, y: 20))])
        #expect(encoder.encode(.gesture(kind: .rotate, at: origin, value: 0, phase: .began))
            == [.appleEvent(.rotate(0, phase: .began, x: 10, y: 20))])
        #expect(encoder.encode(.gesture(kind: .rotate, at: origin, value: 0, phase: .ended))
            == [.appleEvent(.rotate(0, phase: .ended, x: 10, y: 20))])
        #expect(encoder.encode(.gesture(kind: .smartZoom, at: origin, value: 0, phase: .none)).isEmpty)
    }

    @Test func keysAndTextEncodeAsKeyEventsAndTabletIsDropped() {
        #expect(encoder.encode(.key(KeyStroke(keysym: 0x61, macKeyCode: 0, isDown: true))) == [.keyEvent(isDown: true, keysym: 0x61)])
        #expect(encoder.encode(.text("a\u{1}")) == [.keyEvent(isDown: true, keysym: 0x61), .keyEvent(isDown: false, keysym: 0x61)])
        #expect(encoder.encode(.tablet(at: origin, pressure: 0.5, tiltX: 0.1, tiltY: 0.2)).isEmpty)
    }

    @Test func encodingABatchKeepsOrder() {
        let batch: [InputIntent] = [.key(0x41, isDown: true), .pointer(at: origin, buttons: .left, modifiers: nil), .key(0x41, isDown: false)]
        #expect(encoder.encode(batch) == [.keyEvent(isDown: true, keysym: 0x41), pointer(1, 10, 20), .keyEvent(isDown: false, keysym: 0x41)])
    }
}

private struct FlatSpace: RemoteCoordinateSpace {
    var remoteSize = CGSize(width: 2000, height: 1000)
    var pointsPerRemotePixel = 1.0
    func remotePixel(forView point: CGPoint, clamped: Bool) -> (x: Int, y: Int)? { (Int(point.x), Int(point.y)) }
}

@Suite("TouchMapper intents are protocol-neutral")
struct TouchMapperIntentTests {
    @Test func clickCarriesLogicalButtonsNotWheelBits() {
        var mapper = TouchMapper()
        let at = RemotePoint(x: 30, y: 40)
        let output = mapper.handle(.tap(CGPoint(x: 30, y: 40), count: 1), in: FlatSpace(), isZoomed: false)
        #expect(output.intents == [
            .pointer(at: at, buttons: [], modifiers: nil), .pointer(at: at, buttons: .left, modifiers: nil), .pointer(at: at, buttons: [], modifiers: nil),
        ])
    }

    @Test func lineScrollIsOneIntentInTheScrollingDeltaConvention() {
        var mapper = TouchMapper()
        let at = CGPoint(x: 30, y: 40)
        // Natural scrolling, fingers moving up two ticks: content moves up, dy is negative.
        let output = mapper.handle(.twoFingerPan(location: at, translation: CGPoint(x: 0, y: -48), .changed), in: FlatSpace(), isZoomed: false)
        #expect(output.intents == [
            .scroll(at: RemotePoint(x: 30, y: 40), buttons: [], dx: 0, dy: -2, phase: .none, momentumPhase: .none, isContinuous: false),
        ])
    }

    @Test func smoothScrollCarriesPhasesAndMomentum() {
        var policy = TouchPolicy()
        policy.appleSmoothScroll = true
        var mapper = TouchMapper(policy: policy)
        let at = CGPoint(x: 30, y: 40)
        let point = RemotePoint(x: 30, y: 40)
        var all: [InputIntent] = []
        all += mapper.handle(.twoFingerPan(location: at, translation: .zero, .began), in: FlatSpace(), isZoomed: false).intents
        all += mapper.handle(.twoFingerPan(location: at, translation: CGPoint(x: 0, y: 8), .changed), in: FlatSpace(), isZoomed: false).intents
        all += mapper.handle(.twoFingerPan(location: at, translation: .zero, .ended), in: FlatSpace(), isZoomed: false).intents
        all += mapper.handle(.twoFingerPan(location: at, translation: CGPoint(x: 0, y: 2), .changed), in: FlatSpace(), isZoomed: false).intents
        all += mapper.handle(.twoFingerPan(location: at, translation: .zero, .ended), in: FlatSpace(), isZoomed: false).intents
        func step(_ dy: Double, _ phase: InputPhase, _ momentum: InputPhase) -> InputIntent {
            .scroll(at: point, buttons: [], dx: 0, dy: dy, phase: phase, momentumPhase: momentum, isContinuous: true)
        }
        #expect(all == [step(0, .began, .none), step(8, .changed, .none), step(0, .ended, .none), step(2, .none, .began), step(0, .none, .ended)])
    }

    @Test func pinchIsAGestureIntent() {
        var mapper = TouchMapper()
        let at = CGPoint(x: 30, y: 40)
        let point = RemotePoint(x: 30, y: 40)
        let output = mapper.handle(.magnify(location: at, scaleDelta: 0.2, .began), in: FlatSpace(), isZoomed: false)
        #expect(output.intents == [
            .pointer(at: point, buttons: [], modifiers: nil),
            .gesture(kind: .magnify, at: point, value: 0, phase: .began),
            .gesture(kind: .magnify, at: point, value: 0.2, phase: .changed),
        ])
    }

    @Test func intentCoordinatesAreNotClampedByTheMapper() {
        // Clamping to the wire range is the encoder's job: another protocol may allow other ranges.
        struct Far: RemoteCoordinateSpace {
            var remoteSize = CGSize(width: 100, height: 100)
            var pointsPerRemotePixel = 1.0
            func remotePixel(forView point: CGPoint, clamped: Bool) -> (x: Int, y: Int)? { (200_000, -5) }
        }
        var mapper = TouchMapper()
        let output = mapper.handle(.hover(.zero), in: Far(), isZoomed: false)
        #expect(output.intents == [.pointer(at: RemotePoint(x: 200_000, y: -5), buttons: [], modifiers: nil)])
        #expect(output.intents.rfb == [pointer(0, 65535, 0)])
    }
}

@Suite("PointerActions over intents")
struct IntentPointerActionsTests {
    @Test func detectsAButtonActionCompleting() {
        var previous: PointerButtons = []
        let point = RemotePoint(x: 1, y: 1)
        #expect(!PointerActions.completesAButtonAction([.pointer(at: point, buttons: .left, modifiers: nil)], previousButtons: &previous))
        #expect(previous == .left)
        #expect(PointerActions.completesAButtonAction([.pointer(at: point, buttons: [], modifiers: nil)], previousButtons: &previous))
        #expect(previous.isEmpty)
    }

    @Test func nonPointerIntentsAndSmoothScrollDoNotChangeState() {
        var previous: PointerButtons = .left
        let smooth = InputIntent.scroll(at: origin, buttons: [], dx: 0, dy: 1, phase: .changed, momentumPhase: .none, isContinuous: true)
        #expect(!PointerActions.completesAButtonAction([.key(0x61, isDown: true), smooth], previousButtons: &previous))
        #expect(previous == .left)
    }

    @Test func lineScrollCarriesTheHeldButtonsLikeItsWheelTicksDid() {
        var previous: PointerButtons = .left
        let line = InputIntent.scroll(at: origin, buttons: .left, dx: 0, dy: 1, phase: .none, momentumPhase: .none, isContinuous: false)
        #expect(!PointerActions.completesAButtonAction([line], previousButtons: &previous))
        #expect(previous == .left)
    }
}
