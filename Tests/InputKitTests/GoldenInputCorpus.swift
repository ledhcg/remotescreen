import CoreGraphics
import Foundation
import RFBKit
@testable import InputKit

/// Scenario corpus whose RFB output is pinned by `GoldenInputTests`. All scenarios run through `GoldenRig`, the only place that
/// knows which input API is in use, so the same scenario text can be replayed after the pipeline changes.
struct GoldenSpace: RemoteCoordinateSpace {
    var remoteSize = CGSize(width: 2000, height: 1000)
    var pointsPerRemotePixel = 0.5
    var origin = CGPoint(x: 0, y: 50)
    /// Returns pixels far outside the 16-bit range to exercise clamping.
    var wild = false

    func remotePixel(forView point: CGPoint, clamped: Bool) -> (x: Int, y: Int)? {
        let x = Int(((point.x - origin.x) / pointsPerRemotePixel).rounded(.down))
        let y = Int(((point.y - origin.y) / pointsPerRemotePixel).rounded(.down))
        if wild { return (x * 1000, y * 1000) }
        if (0..<2000).contains(x) && (0..<1000).contains(y) { return (x, y) }
        guard clamped else { return nil }
        return (min(max(x, 0), 1999), min(max(y, 0), 999))
    }
}

func goldenDescribe(_ message: ClientMessage) -> String {
    switch message {
    case .pointerEvent(let buttons, let x, let y): "P b=\(buttons) \(x),\(y)"
    case .keyEvent(let isDown, let keysym): "K \(isDown ? "dn" : "up") 0x\(String(keysym, radix: 16))"
    default: String(describing: message)
    }
}

let goldenAt = CGPoint(x: 100, y: 150)

/// Every scenario, in a stable order. Each returns one line per step.
func goldenScenarios() -> [(name: String, lines: [String])] {
    var result: [(String, [String])] = []
    func scenario(_ name: String, policy: TouchPolicy = TouchPolicy(), initial: (x: Int, y: Int)? = nil,
                  space: GoldenSpace = GoldenSpace(), _ body: (inout GoldenRig) -> Void) {
        var rig = GoldenRig(policy: policy, initial: initial, space: space)
        body(&rig)
        result.append((name, rig.log))
    }
    var trackpad = TouchPolicy(mode: .trackpad)
    trackpad.trackpadSensitivity = 1.6
    var plainScroll = TouchPolicy()
    plainScroll.naturalScrolling = false
    var smooth = TouchPolicy()
    smooth.appleSmoothScroll = true
    var smoothUnnatural = smooth
    smoothUnnatural.naturalScrolling = false
    var smoothTrackpad = trackpad
    smoothTrackpad.appleSmoothScroll = true
    var retina = smooth
    retina.remotePixelsPerMacPoint = 2
    var shortTick = TouchPolicy()
    shortTick.scrollTickDistance = 10

    // Taps and clicks
    scenario("tap.direct") { $0.touch(.tap(goldenAt, count: 1)) }
    scenario("tap.double") { $0.touch(.tap(goldenAt, count: 2)) }
    scenario("tap.countZero") { $0.touch(.tap(goldenAt, count: 0)) }
    scenario("tap.blackBar") { $0.touch(.tap(CGPoint(x: 100, y: 20), count: 1)); $0.touch(.twoFingerTap(CGPoint(x: 100, y: 20))) }
    scenario("tap.twoFinger") { $0.touch(.twoFingerTap(goldenAt)) }
    scenario("tap.trackpad", policy: trackpad, initial: (10, 20)) {
        $0.touch(.tap(CGPoint(x: 900, y: 900), count: 1)); $0.touch(.twoFingerTap(.zero))
    }
    scenario("tap.trackpadUnknownPointer", policy: trackpad) { $0.touch(.tap(goldenAt, count: 1)) }

    // Pointer movement, drag
    scenario("pan.direct") {
        $0.touch(.pan(location: CGPoint(x: 50, y: 100), translation: CGPoint(x: 5, y: 5), .changed))
        $0.touch(.pan(location: CGPoint(x: 50, y: 10), translation: .zero, .began))
        $0.touch(.pan(location: CGPoint(x: 5000, y: 5000), translation: .zero, .ended))
    }
    scenario("pan.trackpad", policy: trackpad, initial: (10, 20)) {
        $0.touch(.pan(location: .zero, translation: CGPoint(x: 10, y: 5), .changed))
        $0.touch(.pan(location: .zero, translation: CGPoint(x: 10, y: 5), .began))
        $0.touch(.pan(location: .zero, translation: CGPoint(x: -100000, y: -100000), .changed))
        $0.touch(.pan(location: .zero, translation: CGPoint(x: 100000, y: 100000), .changed))
    }
    scenario("pan.trackpadUnknownPointer", policy: trackpad) {
        $0.touch(.pan(location: .zero, translation: CGPoint(x: 3, y: 3), .changed))
    }
    scenario("pan.zoomedPansViewport") {
        $0.touch(.pan(location: goldenAt, translation: CGPoint(x: 7, y: 8), .changed), zoomed: true)
        $0.touch(.pan(location: goldenAt, translation: CGPoint(x: 7, y: 8), .began), zoomed: true)
    }
    scenario("pan.trackpadZoomed", policy: trackpad, initial: (5, 5)) {
        $0.touch(.pan(location: goldenAt, translation: CGPoint(x: 7, y: 8), .changed), zoomed: true)
    }
    scenario("longPress.directDrag") {
        $0.touch(.longPress(goldenAt, .began))
        $0.touch(.longPress(CGPoint(x: 120, y: 160), .changed))
        $0.touch(.longPress(CGPoint(x: 400, y: 5000), .changed))
        $0.touch(.longPress(CGPoint(x: 130, y: 170), .ended))
        $0.touch(.longPress(CGPoint(x: 130, y: 170), .changed))
    }
    scenario("longPress.trackpadDrag", policy: trackpad, initial: (100, 100)) {
        $0.touch(.longPress(goldenAt, .began))
        $0.touch(.longPress(CGPoint(x: 110, y: 155), .changed))
        $0.touch(.longPress(CGPoint(x: 120, y: 165), .changed))
        $0.touch(.longPress(CGPoint(x: 120, y: 165), .ended))
    }
    scenario("longPress.blackBar") {
        $0.touch(.longPress(CGPoint(x: 100, y: 10), .began))
        $0.touch(.longPress(goldenAt, .changed))
        $0.touch(.longPress(goldenAt, .ended))
    }
    scenario("longPress.releaseAllMidDrag") {
        $0.touch(.longPress(goldenAt, .began))
        $0.releaseTouch()
        $0.releaseTouch()
        $0.touch(.longPress(goldenAt, .changed))
    }

    // Pencil
    scenario("pencil.click") { $0.touch(.pencil(.click(goldenAt))); $0.touch(.pencil(.rightClick(goldenAt))) }
    scenario("pencil.blackBar") { $0.touch(.pencil(.click(CGPoint(x: 100, y: 10)))); $0.touch(.pencil(.rightClick(CGPoint(x: 100, y: 10)))) }
    scenario("pencil.drag") {
        $0.touch(.pencil(.press(goldenAt)))
        $0.touch(.pencil(.move(CGPoint(x: 110, y: 150))))
        $0.touch(.pencil(.release(CGPoint(x: 120, y: 150))))
    }
    scenario("pencil.trackpadStillAbsolute", policy: trackpad, initial: (1, 1)) {
        $0.touch(.pencil(.press(goldenAt))); $0.touch(.pencil(.release(goldenAt)))
    }
    scenario("pencil.releaseAllMidStroke") {
        $0.touch(.pencil(.press(goldenAt))); $0.releaseTouch()
    }
    scenario("pencil.doubleTapSecondary") {
        $0.touch(.secondaryClickAtPointer)
        $0.touch(.hover(goldenAt))
        $0.touch(.secondaryClickAtPointer)
    }

    // Hover, mouse
    scenario("hover") {
        $0.touch(.hover(goldenAt)); $0.touch(.hover(CGPoint(x: 99999, y: 99999))); $0.touch(.hover(CGPoint(x: -50, y: -50)))
    }
    scenario("mouse.clickAndDrag") {
        $0.touch(.mouseButton(goldenAt, .primary, .began))
        $0.touch(.mouseButton(CGPoint(x: 110, y: 160), .primary, .changed))
        $0.touch(.mouseButton(CGPoint(x: 120, y: 170), .primary, .ended))
        $0.touch(.mouseButton(goldenAt, .secondary, .began))
        $0.touch(.mouseButton(goldenAt, .secondary, .ended))
    }
    scenario("mouse.bothButtons") {
        $0.touch(.mouseButton(goldenAt, .primary, .began))
        $0.touch(.mouseButton(goldenAt, .secondary, .began))
        $0.touch(.mouseButton(goldenAt, .primary, .ended))
        $0.touch(.mouseButton(goldenAt, .secondary, .ended))
    }
    scenario("mouse.releaseAllWhileHeld") {
        $0.touch(.mouseButton(goldenAt, .primary, .began)); $0.releaseTouch()
    }
    scenario("mouse.dragThenTap") {
        $0.touch(.mouseButton(goldenAt, .primary, .began))
        $0.touch(.tap(CGPoint(x: 200, y: 200), count: 1))
        $0.touch(.twoFingerTap(CGPoint(x: 220, y: 220)))
    }

    // Wheel ticks
    scenario("wheel.twoFingerDirect") {
        $0.touch(.twoFingerPan(location: goldenAt, translation: .zero, .began))
        $0.touch(.twoFingerPan(location: goldenAt, translation: CGPoint(x: 0, y: -24), .changed))
        $0.touch(.twoFingerPan(location: goldenAt, translation: CGPoint(x: 0, y: 12), .changed))
        $0.touch(.twoFingerPan(location: goldenAt, translation: CGPoint(x: 0, y: 12), .changed))
        $0.touch(.twoFingerPan(location: goldenAt, translation: CGPoint(x: -50, y: 75), .changed))
        $0.touch(.twoFingerPan(location: goldenAt, translation: .zero, .ended))
    }
    scenario("wheel.unnatural", policy: plainScroll) {
        $0.touch(.twoFingerPan(location: goldenAt, translation: CGPoint(x: 49, y: -49), .changed))
        $0.touch(.twoFingerPan(location: goldenAt, translation: CGPoint(x: -49, y: 49), .changed))
    }
    scenario("wheel.tickDistance10", policy: shortTick) {
        $0.touch(.twoFingerPan(location: goldenAt, translation: CGPoint(x: 33, y: -27), .changed))
    }
    scenario("wheel.trackpadAtPointer", policy: trackpad, initial: (300, 400)) {
        $0.touch(.twoFingerPan(location: goldenAt, translation: CGPoint(x: 0, y: -48), .changed))
    }
    scenario("wheel.trackpadUnknownPointer", policy: trackpad) {
        $0.touch(.twoFingerPan(location: goldenAt, translation: CGPoint(x: 0, y: -48), .changed))
    }
    scenario("wheel.zoomedPansViewport") {
        $0.touch(.twoFingerPan(location: goldenAt, translation: CGPoint(x: 5, y: -48), .changed), zoomed: true)
    }
    scenario("wheel.mouseWheelAtLocation", policy: trackpad, initial: (1, 1)) {
        $0.touch(.scroll(location: goldenAt, translation: .zero, .began), zoomed: true)
        $0.touch(.scroll(location: goldenAt, translation: CGPoint(x: 0, y: -24), .changed), zoomed: true)
        $0.touch(.scroll(location: goldenAt, translation: CGPoint(x: 0, y: -24), .ended), zoomed: true)
    }
    scenario("wheel.whileButtonHeld") {
        $0.touch(.mouseButton(goldenAt, .primary, .began))
        $0.touch(.scroll(location: goldenAt, translation: CGPoint(x: 24, y: 24), .changed))
        $0.touch(.mouseButton(goldenAt, .primary, .ended))
    }
    scenario("wheel.resetOnBegan") {
        $0.touch(.twoFingerPan(location: goldenAt, translation: CGPoint(x: 0, y: -20), .changed))
        $0.touch(.twoFingerPan(location: goldenAt, translation: .zero, .began))
        $0.touch(.twoFingerPan(location: goldenAt, translation: CGPoint(x: 0, y: -20), .changed))
    }
    scenario("wheel.wildCoordinates", space: GoldenSpace(wild: true)) {
        $0.touch(.twoFingerPan(location: goldenAt, translation: CGPoint(x: 0, y: -48), .changed))
        $0.touch(.tap(goldenAt, count: 1))
        $0.touch(.hover(goldenAt))
        $0.releaseTouch()
    }

    // Apple smooth scrolling
    scenario("smooth.sequence", policy: smooth) {
        $0.touch(.twoFingerPan(location: goldenAt, translation: .zero, .began))
        $0.touch(.twoFingerPan(location: goldenAt, translation: CGPoint(x: 0, y: 10), .changed))
        $0.touch(.twoFingerPan(location: goldenAt, translation: CGPoint(x: 4, y: 0.4), .changed))
        $0.touch(.twoFingerPan(location: goldenAt, translation: CGPoint(x: 0, y: 0.3), .changed))
        $0.touch(.twoFingerPan(location: goldenAt, translation: .zero, .ended))
        // Momentum: changed after ended.
        $0.touch(.twoFingerPan(location: goldenAt, translation: CGPoint(x: 0, y: 6), .changed))
        $0.touch(.twoFingerPan(location: goldenAt, translation: CGPoint(x: 0, y: 3), .changed))
        $0.touch(.twoFingerPan(location: goldenAt, translation: .zero, .ended))
        $0.touch(.twoFingerPan(location: goldenAt, translation: .zero, .ended))
    }
    scenario("smooth.unnatural", policy: smoothUnnatural) {
        $0.touch(.twoFingerPan(location: goldenAt, translation: .zero, .began))
        $0.touch(.twoFingerPan(location: goldenAt, translation: CGPoint(x: -7, y: 12.7), .changed))
        $0.touch(.twoFingerPan(location: goldenAt, translation: .zero, .ended))
    }
    scenario("smooth.retina", policy: retina) {
        $0.touch(.twoFingerPan(location: goldenAt, translation: .zero, .began))
        $0.touch(.twoFingerPan(location: goldenAt, translation: CGPoint(x: 9, y: -21), .changed))
        $0.touch(.twoFingerPan(location: goldenAt, translation: .zero, .ended))
    }
    scenario("smooth.trackpadPointer", policy: smoothTrackpad, initial: (700, 800)) {
        $0.touch(.twoFingerPan(location: goldenAt, translation: .zero, .began))
        $0.touch(.twoFingerPan(location: goldenAt, translation: CGPoint(x: 0, y: -30), .changed))
        $0.touch(.twoFingerPan(location: goldenAt, translation: .zero, .ended))
    }
    scenario("smooth.mouseScrollAtLocation", policy: smoothTrackpad, initial: (700, 800)) {
        $0.touch(.scroll(location: goldenAt, translation: .zero, .began))
        $0.touch(.scroll(location: goldenAt, translation: CGPoint(x: 3, y: -30), .changed))
        $0.touch(.scroll(location: goldenAt, translation: .zero, .ended))
    }
    scenario("smooth.hugeDelta", policy: smooth) {
        $0.touch(.twoFingerPan(location: goldenAt, translation: .zero, .began))
        $0.touch(.twoFingerPan(location: goldenAt, translation: CGPoint(x: 1e15, y: -1e15), .changed))
        $0.touch(.twoFingerPan(location: goldenAt, translation: .zero, .ended))
    }
    scenario("smooth.wild", policy: smooth, space: GoldenSpace(wild: true)) {
        $0.touch(.twoFingerPan(location: goldenAt, translation: .zero, .began))
        $0.touch(.twoFingerPan(location: goldenAt, translation: CGPoint(x: 5, y: 5), .changed))
    }
    scenario("smooth.panViewportZoomed", policy: smooth) {
        $0.touch(.twoFingerPan(location: goldenAt, translation: CGPoint(x: 5, y: 5), .changed), zoomed: true)
    }

    // Pinch and rotate
    scenario("gesture.magnify") {
        $0.touch(.magnify(location: goldenAt, scaleDelta: 0, .began))
        $0.touch(.magnify(location: goldenAt, scaleDelta: 0.1, .changed))
        $0.touch(.rotate(location: goldenAt, degrees: -12, .changed))
        $0.touch(.magnify(location: goldenAt, scaleDelta: 0, .ended))
    }
    scenario("gesture.valueOnBeganAndEnded") {
        $0.touch(.rotate(location: goldenAt, degrees: 4, .began))
        $0.touch(.rotate(location: goldenAt, degrees: -1, .ended))
        $0.touch(.magnify(location: goldenAt, scaleDelta: 0.2, .began))
        $0.touch(.magnify(location: goldenAt, scaleDelta: 0.2, .ended))
    }
    scenario("gesture.whileButtonHeldKeepsPointer") {
        $0.touch(.mouseButton(CGPoint(x: 300, y: 300), .primary, .began))
        $0.touch(.magnify(location: goldenAt, scaleDelta: 0.1, .began))
        $0.touch(.magnify(location: goldenAt, scaleDelta: 0.1, .changed))
        $0.touch(.magnify(location: goldenAt, scaleDelta: 0, .ended))
    }
    scenario("gesture.blackBarClampsAndFar") {
        $0.touch(.magnify(location: CGPoint(x: 100, y: 10), scaleDelta: 0.1, .began))
        $0.touch(.rotate(location: CGPoint(x: 99999, y: 99999), degrees: 3, .changed))
    }
    scenario("gesture.wild", space: GoldenSpace(wild: true)) {
        $0.touch(.magnify(location: goldenAt, scaleDelta: 0.1, .began))
        $0.touch(.magnify(location: goldenAt, scaleDelta: .nan, .changed))
    }
    scenario("gesture.afterTrackpadMove", policy: trackpad, initial: (50, 60)) {
        $0.touch(.magnify(location: goldenAt, scaleDelta: 0.1, .began))
        $0.touch(.magnify(location: goldenAt, scaleDelta: 0.1, .ended))
    }

    // Button-action completion (modifier release hook)
    scenario("actions.completion") {
        $0.touch(.mouseButton(goldenAt, .primary, .began))
        $0.touch(.mouseButton(goldenAt, .primary, .changed))
        $0.touch(.mouseButton(goldenAt, .primary, .ended))
        $0.touch(.tap(goldenAt, count: 1))
        $0.touch(.longPress(goldenAt, .began))
        $0.touch(.longPress(goldenAt, .ended))
        $0.touch(.twoFingerPan(location: goldenAt, translation: CGPoint(x: 0, y: -48), .changed))
        $0.touch(.mouseButton(goldenAt, .primary, .began))
        $0.touch(.scroll(location: goldenAt, translation: CGPoint(x: 0, y: -48), .changed))
        $0.touch(.mouseButton(goldenAt, .primary, .ended))
    }

    // Keyboard
    scenario("keys.letters") {
        $0.key(0x04, "a", "a", [], down: true); $0.key(0x04, "a", "a", [], down: false)
        $0.key(0xE1, "", "", [.shift], down: true)
        $0.key(0x04, "A", "a", [.shift], down: true)
        $0.key(0xE1, "", "", [], down: false)
        $0.key(0x04, "a", "a", [], down: false)
    }
    scenario("keys.releaseUsesPressKeysym") {
        $0.key(0x04, "A", "a", [.shift], down: true)
        $0.key(0x04, "a", "a", [], down: false)
        $0.key(0x04, "a", "a", [], down: false)
    }
    scenario("keys.modifiersAndSpecials") {
        let keys: [(Int, KeyModifiers)] = [
            (0xE3, .command), (0xE0, .control), (0xE2, .option), (0x28, []), (0x2A, []), (0x4F, []), (0x3A, []), (0x68, []), (0x39, []),
        ]
        for (hid, mods) in keys { $0.key(hid, "", "", mods, down: true) }
        $0.releaseKeys()
        $0.releaseKeys()
    }
    scenario("keys.chordsWithModifiersUseBaseCharacter") {
        $0.key(0xE3, "", "", [.command], down: true)
        $0.key(0x06, "\u{3}", "c", [.command], down: true)
        $0.key(0x06, "c", "c", [], down: false)
        $0.key(0x1B, "≈", "x", [.option], down: true)
        $0.key(0x1B, "x", "x", [], down: false)
    }
    scenario("keys.unicodeAndUnsendable") {
        $0.key(0x01, "é", "é", [], down: true)
        $0.key(0x02, "ệ", "ệ", [], down: true)
        $0.key(0x03, "😀", "😀", [], down: true)
        $0.key(0x05, "\u{7}", "\u{7}", [], down: true)
        $0.key(0x06, "", "", [], down: true)
        $0.key(0x07, "\u{A0}", "\u{A0}", [], down: true)
        $0.releaseKeys()
    }
    scenario("keys.repeatResendsPress") {
        $0.key(0x2A, "", "", [], down: true)
        $0.key(0x2A, "", "", [], down: true)
        $0.key(0x2A, "", "", [], down: false)
    }
    scenario("typing") {
        for text in ["abc", "Hello, World!", "line1\nline2\r\tx", "Tiếng Việt ệ", "😀x", "\u{1}\u{7F}", "", " ~\u{A0}\u{FF}\u{100}"] {
            $0.typing(text)
        }
    }
    scenario("chord") {
        let cases: [(String, Bool)] = [("f", false), ("F", false), ("z", true), ("Z", true), ("é", false), ("é", true), ("😀", false), ("\n", false)]
        for (character, down) in cases { $0.chord(Character(character), commandAlreadyDown: down) }
    }
    scenario("virtualKeys") {
        for key in VirtualKey.allCases { $0.virtual(key) }
    }

    // Modifier keys
    scenario("modifiers.holdAndUse") {
        $0.modDown(.command, 0)
        $0.modAction()
        $0.modAction()
        $0.modUp(.command, 2)
        $0.modUp(.command, 3)
    }
    scenario("modifiers.oneShot") {
        $0.modDown(.shift, 0); $0.modUp(.shift, 0.1)
        $0.modAction()
        $0.modAction()
    }
    scenario("modifiers.longHoldNoUse") {
        $0.modDown(.control, 0); $0.modUp(.control, 5)
    }
    scenario("modifiers.doubleTapLock") {
        $0.modTap(.command, 0); $0.modTap(.command, 0.2); $0.modAction(); $0.modTap(.command, 5)
    }
    scenario("modifiers.slowSecondTapDrops") {
        $0.modTap(.option, 0); $0.modTap(.option, 2)
    }
    scenario("modifiers.lockedHoldUnlocks") {
        $0.modTap(.shift, 0); $0.modTap(.shift, 0.1)
        $0.modDown(.shift, 3); $0.modUp(.shift, 3.2)
    }
    scenario("modifiers.releaseAllReverseOrder") {
        $0.modDown(.control, 0); $0.modTap(.shift, 1); $0.modTap(.option, 2); $0.modTap(.command, 3); $0.modTap(.command, 3.1)
        $0.modRelease()
        $0.modRelease()
    }
    scenario("modifiers.actionCompletedReverseOrder") {
        $0.modTap(.control, 0); $0.modTap(.shift, 1); $0.modDown(.option, 2)
        $0.modAction()
        $0.modUp(.option, 9)
    }
    return result
}
