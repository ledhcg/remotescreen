import CoreGraphics
import Foundation
import RFBKit
@testable import InputKit

/// Drives the input pipeline for the golden corpus and records one line per step. This file is the only one that depends on how
/// input is produced (messages directly, or intents followed by `RFBInputEncoder`).
struct GoldenRig {
    var mapper: TouchMapper
    var keyboard = KeyboardState()
    var modifiers = ModifierKeys()
    let space: GoldenSpace
    var previousButtons: UInt8 = 0
    var log: [String] = []

    init(policy: TouchPolicy, initial: (x: Int, y: Int)?, space: GoldenSpace) {
        mapper = TouchMapper(policy: policy, initialPointer: initial)
        self.space = space
    }

    private mutating func record(_ label: String, _ messages: [ClientMessage], extra: String = "") {
        log.append("\(label) -> [\(messages.map(goldenDescribe).joined(separator: "; "))]\(extra)")
    }

    mutating func touch(_ event: TouchEvent, zoomed: Bool = false) {
        let output = mapper.handle(event, in: space, isZoomed: zoomed)
        let completes = PointerActions.completesAButtonAction(output.messages, previousButtons: &previousButtons)
        var extra = completes ? " done" : ""
        if let pan = output.viewportPan { extra += " pan(\(pan.x),\(pan.y))" }
        record("\(event)", output.messages, extra: extra)
    }

    mutating func releaseTouch() { record("touchReleaseAll", mapper.releaseAll()) }

    mutating func key(_ hid: Int, _ characters: String, _ ignoring: String, _ mods: KeyModifiers, down: Bool) {
        let press = KeyPress(hidUsage: hid, characters: characters, charactersIgnoringModifiers: ignoring, modifiers: mods, isDown: down)
        let messages = keyboard.handle(press)
        record("key hid=\(hid) \(down ? "dn" : "up")", messages, extra: " repeating=\(keyboard.repeating.map { "\($0.hidUsage):\($0.keysym)" } ?? "-")")
    }

    mutating func releaseKeys() { record("keysReleaseAll", keyboard.releaseAll()) }
    mutating func typing(_ text: String) { record("typing \(text.debugDescription)", KeyboardState.typing(text)) }
    mutating func chord(_ character: Character, commandAlreadyDown: Bool) {
        record("chord \(character) cmdDown=\(commandAlreadyDown)", KeysymMapper.commandChord(character, commandAlreadyDown: commandAlreadyDown) ?? [])
    }
    mutating func virtual(_ key: VirtualKey) { record("virtual \(key)", key.tap) }

    mutating func modDown(_ m: StickyModifier, _ t: Double) { record("modDown \(m)@\(t)", modifiers.touchDown(m, at: t), extra: state()) }
    mutating func modUp(_ m: StickyModifier, _ t: Double) { record("modUp \(m)@\(t)", modifiers.touchUp(m, at: t), extra: state()) }
    mutating func modTap(_ m: StickyModifier, _ t: Double) { record("modTap \(m)@\(t)", modifiers.tap(m, at: t), extra: state()) }
    mutating func modAction() { record("modAction", modifiers.actionCompleted(), extra: state()) }
    mutating func modRelease() { record("modReleaseAll", modifiers.releaseAll(), extra: state()) }

    private func state() -> String {
        " state=\(modifiers.active.map { "\($0):\(modifiers.state(of: $0))" })"
    }
}
