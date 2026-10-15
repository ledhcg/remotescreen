import Foundation
import InputKit
import LinkProtocol
import Testing
@testable import WindowKit

@Suite("LinkInputEncoder")
struct LinkInputEncoderTests {
    private func encoder() -> LinkInputEncoder { LinkInputEncoder(window: 7) }

    @Test func pointerCarriesButtonsAndModifiers() {
        var e = encoder()
        let out = e.encode(.pointer(at: RemotePoint(x: 10.5, y: 20.25), buttons: [.left, .right, .middle], modifiers: [.shift, .command]))
        #expect(out == [.inputPointer(LinkPointerEvent(
            window: 7, point: LinkPoint(x: 10.5, y: 20.25), buttons: [.left, .right, .middle], modifiers: [.shift, .command]
        ))])
    }

    @Test func buttonBitsAreRemappedNotCopied() {
        // InputKit: left 1, middle 2, right 4. Link: left 1, right 2, middle 4.
        var e = encoder()
        guard case .inputPointer(let m)? = e.encode(.pointer(at: RemotePoint(x: 0, y: 0), buttons: .right, modifiers: nil)).first else {
            Issue.record("expected pointer")
            return
        }
        #expect(m.buttons == .right)
        guard case .inputPointer(let n)? = e.encode(.pointer(at: RemotePoint(x: 0, y: 0), buttons: .middle, modifiers: nil)).first else {
            Issue.record("expected pointer")
            return
        }
        #expect(n.buttons == .middle)
    }

    @Test func pointerWithoutModifierHintUsesTrackedKeys() {
        var e = encoder()
        _ = e.encode(.key(0xFFE3, macKeyCode: 59, isDown: true)) // Control down
        guard case .inputPointer(let m)? = e.encode(.pointer(at: RemotePoint(x: 1, y: 1), buttons: .left, modifiers: nil)).first else {
            Issue.record("expected pointer")
            return
        }
        #expect(m.modifiers == .control)
    }

    @Test func tabletBecomesPointerWithPressureAndTilt() {
        var e = encoder()
        let out = e.encode(.tablet(at: RemotePoint(x: 5, y: 6), pressure: 0.5, tiltX: 0.25, tiltY: -0.5))
        #expect(out == [.inputPointer(LinkPointerEvent(
            window: 7, point: LinkPoint(x: 5, y: 6), buttons: .left, modifiers: [], pressure: 0.5, tilt: LinkTilt(x: 0.25, y: -0.5)
        ))])
        // Hovering (no pressure) is a move with no button.
        guard case .inputPointer(let hover)? = e.encode(.tablet(at: RemotePoint(x: 5, y: 6), pressure: 0, tiltX: 0, tiltY: 0)).first else {
            Issue.record("expected pointer")
            return
        }
        #expect(hover.buttons.isEmpty && hover.pressure == 0)
    }

    @Test func tabletValuesStayInTheRangeTheCodecAccepts() throws {
        var e = encoder()
        let out = e.encode(.tablet(at: RemotePoint(x: 1, y: 1), pressure: 7, tiltX: 100, tiltY: .nan))
        guard case .inputPointer(let m)? = out.first else {
            Issue.record("expected pointer")
            return
        }
        #expect(m.pressure == 1)
        #expect(m.tilt == LinkTilt(x: Float(2 * Double.pi).nextDown, y: 0))
        // The result must survive the real encoder.
        _ = try out.map { try LinkFrameEncoder.encode($0) }
    }

    @Test func scrollSendsPointerFirstThenScroll() {
        var e = encoder()
        let intent = InputIntent.scroll(
            at: RemotePoint(x: 30, y: 40), buttons: [], dx: 1.5, dy: -12, phase: .began, momentumPhase: .none, isContinuous: true
        )
        let out = e.encode(intent)
        #expect(out == [
            .inputPointer(LinkPointerEvent(window: 7, point: LinkPoint(x: 30, y: 40), buttons: [], modifiers: [])),
            .inputScroll(LinkScrollEvent(window: 7, dx: 1.5, dy: -12, phase: .began, momentumPhase: .none, continuous: true)),
        ])
        // The pointer is already there: only the scroll event is sent.
        let again = e.encode(.scroll(at: RemotePoint(x: 30, y: 40), buttons: [], dx: 0, dy: -3, phase: .changed, momentumPhase: .none, isContinuous: true))
        #expect(again == [.inputScroll(LinkScrollEvent(window: 7, dx: 0, dy: -3, phase: .changed, momentumPhase: .none, continuous: true))])
    }

    @Test(arguments: [(InputPhase.none, LinkScrollPhase.none), (.began, .began), (.changed, .changed), (.ended, .ended)])
    func scrollPhasesAndMomentumMap(phase: InputPhase, expected: LinkScrollPhase) {
        var e = encoder()
        let out = e.encode(.scroll(at: RemotePoint(x: 0, y: 0), buttons: [], dx: 0, dy: 1, phase: phase, momentumPhase: phase, isContinuous: false))
        guard case .inputScroll(let m)? = out.last else {
            Issue.record("expected scroll")
            return
        }
        #expect(m.phase == expected && m.momentumPhase == expected && !m.continuous)
    }

    @Test func nonFiniteDeltasAndPointsAreHandled() throws {
        var e = encoder()
        let out = e.encode(.scroll(at: RemotePoint(x: 0, y: 0), buttons: [], dx: .nan, dy: .infinity, phase: .none, momentumPhase: .none, isContinuous: true))
        #expect(out.last == .inputScroll(LinkScrollEvent(window: 7, dx: 0, dy: 0, phase: .none, momentumPhase: .none, continuous: true)))
        #expect(e.encode(.pointer(at: RemotePoint(x: .nan, y: 0), buttons: [], modifiers: nil)).isEmpty)
        let far = e.encode(.pointer(at: RemotePoint(x: 1e12, y: -1e12), buttons: [], modifiers: nil))
        #expect(far == [.inputPointer(LinkPointerEvent(window: 7, point: LinkPoint(x: 1_000_000, y: -1_000_000), buttons: [], modifiers: []))])
        _ = try far.map { try LinkFrameEncoder.encode($0) }
    }

    @Test func gesturesMapKindAndPhase() {
        var e = encoder()
        let kinds: [(GestureKind, LinkGestureKind)] = [(.magnify, .magnify), (.rotate, .rotate), (.smartZoom, .smartMagnify)]
        for (kind, expected) in kinds {
            let out = e.encode(.gesture(kind: kind, at: RemotePoint(x: 1, y: 2), value: 0.05, phase: .none))
            #expect(out.last == .inputGesture(LinkGestureEvent(window: 7, kind: expected, value: 0.05, phase: .changed)))
        }
        let began = e.encode(.gesture(kind: .magnify, at: RemotePoint(x: 1, y: 2), value: 0, phase: .began))
        #expect(began == [.inputGesture(LinkGestureEvent(window: 7, kind: .magnify, value: 0, phase: .began))])
        let ended = e.encode(.gesture(kind: .magnify, at: RemotePoint(x: 1, y: 2), value: 0, phase: .ended))
        #expect(ended == [.inputGesture(LinkGestureEvent(window: 7, kind: .magnify, value: 0, phase: .ended))])
    }

    @Test func keysUseGivenMacKeyCodeOrTheTableOrTheSentinel() {
        var e = encoder()
        #expect(e.encode(.key(0x61, macKeyCode: 99, isDown: true)) == [.inputKey(LinkKeyEvent(keycode: 99, keysym: 0x61, down: true, modifiers: []))])
        #expect(e.encode(.key(0x61, isDown: false)) == [.inputKey(LinkKeyEvent(keycode: 0, keysym: 0x61, down: false, modifiers: []))])
        #expect(e.encode(.key(0x41, isDown: true)) == [.inputKey(LinkKeyEvent(keycode: 0, keysym: 0x41, down: true, modifiers: []))])
        #expect(e.encode(.key(0xFF0D, isDown: true)) == [.inputKey(LinkKeyEvent(keycode: 36, keysym: 0xFF0D, down: true, modifiers: []))])
        #expect(e.encode(.key(0x1F600, isDown: true)) == [.inputKey(LinkKeyEvent(keycode: LinkInputEncoder.unknownKeycode, keysym: 0x1F600, down: true, modifiers: []))])
    }

    @Test func everyVirtualKeyHasTheSameCodeInTheTableAsInInputKit() {
        for key in VirtualKey.allCases {
            #expect(LinkInputEncoder.macKeyCode(forKeysym: key.keysym) == key.macKeyCode, "\(key)")
        }
        for modifier in StickyModifier.allCases {
            #expect(LinkInputEncoder.macKeyCode(forKeysym: modifier.keysym) == modifier.macKeyCode, "\(modifier)")
        }
    }

    @Test func modifierKeysAreTrackedAndAttachedToLaterKeys() {
        var e = encoder()
        _ = e.encode(StickyModifier.command.keysym == 0 ? [] : [.key(StickyModifier.command.keysym, macKeyCode: 55, isDown: true)])
        _ = e.encode(.key(0xFFE1, macKeyCode: 56, isDown: true))
        #expect(e.modifiers == [.command, .shift])
        let c = e.encode(.key(0x63, macKeyCode: 8, isDown: true))
        #expect(c == [.inputKey(LinkKeyEvent(keycode: 8, keysym: 0x63, down: true, modifiers: [.command, .shift]))])
        _ = e.encode(.key(0xFFE1, macKeyCode: 56, isDown: false))
        _ = e.encode(.key(StickyModifier.command.keysym, macKeyCode: 55, isDown: false))
        #expect(e.modifiers.isEmpty)
        // The modifier's own release carries the state after the change.
        var f = encoder()
        _ = f.encode(.key(0xFFE9, isDown: true))
        let release = f.encode(.key(0xFFE9, isDown: false))
        #expect(release == [.inputKey(LinkKeyEvent(keycode: 58, keysym: 0xFFE9, down: false, modifiers: []))])
    }

    // MARK: Text

    @Test func shortTextIsOneMessage() {
        var e = encoder()
        #expect(e.encode(.text("xin chào")) == [.inputText("xin chào")])
        #expect(e.encode(.text("")).isEmpty)
    }

    @Test func longTextIsChunkedUnderTheCap() {
        let cap = LinkLimits.maxTextInputBytes
        let text = String(repeating: "a", count: cap * 2 + 5)
        let chunks = LinkInputEncoder.chunks(of: text, maxBytes: cap)
        #expect(chunks.map(\.utf8.count) == [cap, cap, 5])
        #expect(chunks.joined() == text)
    }

    @Test func chunksNeverSplitGraphemeClustersOrSurrogatePairs() {
        // Vietnamese with combining marks (decomposed), emoji with ZWJ and skin tone, flags, plain ASCII.
        let pieces = ["Việt Nam", "e\u{0302}\u{0323}", "👩🏽‍💻", "🇻🇳", "😀", "x"]
        let text = String(repeating: pieces.joined(), count: 200)
        for cap in [4, 8, 17, 64, 1024] {
            let chunks = LinkInputEncoder.chunks(of: text, maxBytes: cap)
            #expect(chunks.joined() == text, "cap \(cap)")
            for chunk in chunks {
                #expect(chunk.utf8.count <= cap || chunk.count == 1, "cap \(cap): chunk of \(chunk.utf8.count) bytes")
                #expect(!chunk.isEmpty)
            }
            // Every chunk starts on a grapheme boundary of the original: re-splitting the concatenation gives the same clusters.
            if cap >= 17 { // no single cluster (the longest is 15 bytes) needed splitting
                #expect(chunks.flatMap { Array($0) } == Array(text), "cap \(cap)")
            }
        }
    }

    @Test func aHostileClusterLargerThanTheCapIsSplitBetweenScalarsOnly() {
        let hostile = "a" + String(repeating: "\u{0301}", count: 3000) // one grapheme cluster of ~6000 bytes
        let chunks = LinkInputEncoder.chunks(of: hostile, maxBytes: 1024)
        #expect(chunks.allSatisfy { $0.utf8.count <= 1024 && !$0.isEmpty })
        #expect(chunks.joined() == hostile)
        #expect(chunks.count >= 6)
    }

    @Test func everyEncodedMessageSurvivesTheRealFrameEncoder() throws {
        var e = encoder()
        let text = String(repeating: "Tiếng Việt 😀 ", count: 400)
        let messages = e.encode([
            .text(text), .pointer(at: RemotePoint(x: 1, y: 1), buttons: .left, modifiers: [.option]),
            .scroll(at: RemotePoint(x: 2, y: 2), buttons: [], dx: 1, dy: 1, phase: .changed, momentumPhase: .ended, isContinuous: true),
            .gesture(kind: .rotate, at: RemotePoint(x: 2, y: 2), value: 5, phase: .changed), .tablet(at: RemotePoint(x: 3, y: 3), pressure: 0.3, tiltX: 0.1, tiltY: 0.2),
            .key(0x7A, isDown: true),
        ])
        #expect(messages.count > 6)
        for message in messages {
            let frame = try LinkFrameEncoder.encode(message)
            #expect(!frame.isEmpty)
        }
    }
}
