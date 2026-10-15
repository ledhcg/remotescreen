import Foundation
import InputKit
import LinkProtocol

/// Turns protocol-neutral `InputIntent`s into `LinkMessage`s for one window (the App Mode counterpart of `RFBInputEncoder`).
///
/// Coordinates in the intents are window-relative Mac points (what `WindowCoordinateSpace` produces). The encoder keeps only the
/// little state the wire format needs: the modifier keys currently held (every `input.key` and pointer carries them) and the last
/// pointer position, because `input.scroll` and `input.gesture` have no position of their own and the helper applies them at the
/// pointer. Coalescing pointer moves is the transport's job.
public struct LinkInputEncoder: Sendable {
    /// Sent as the key code when neither the intent nor the keysym table knows the Mac virtual key. The helper then uses `keysym`.
    public static let unknownKeycode: UInt16 = 0xFFFF

    public var window: WindowID
    /// Modifier keys held now. Updated by modifier key strokes; the caller may also set it from the hardware keyboard state.
    public var modifiers: LinkModifiers
    private var lastPointer: LinkPoint?
    private var lastButtons: LinkMouseButtons = []

    public init(window: WindowID, modifiers: LinkModifiers = []) {
        self.window = window
        self.modifiers = modifiers
    }

    public mutating func encode(_ intents: [InputIntent]) -> [LinkMessage] {
        intents.flatMap { encode($0) }
    }

    public mutating func encode(_ intent: InputIntent) -> [LinkMessage] {
        switch intent {
        case .pointer(let point, let buttons, let hint):
            guard let at = Self.point(point) else { return [] }
            return [pointer(at, Self.buttons(buttons), modifiers: hint.map(Self.modifiers) ?? modifiers)]

        case .scroll(let point, let buttons, let dx, let dy, let phase, let momentum, let isContinuous):
            guard let at = Self.point(point) else { return [] }
            var out = positionMessages(at, Self.buttons(buttons))
            out.append(.inputScroll(LinkScrollEvent(
                window: window, dx: Self.delta(dx), dy: Self.delta(dy), phase: Self.scrollPhase(phase),
                momentumPhase: Self.scrollPhase(momentum), continuous: isContinuous
            )))
            return out

        case .gesture(let kind, let point, let value, let phase):
            guard let at = Self.point(point) else { return [] }
            var out = positionMessages(at, lastButtons)
            out.append(.inputGesture(LinkGestureEvent(
                window: window, kind: Self.gestureKind(kind), value: Self.delta(value), phase: Self.gesturePhase(phase)
            )))
            return out

        case .key(let stroke):
            updateModifiers(for: stroke)
            let keycode = stroke.macKeyCode ?? Self.macKeyCode(forKeysym: stroke.keysym) ?? Self.unknownKeycode
            return [.inputKey(LinkKeyEvent(keycode: keycode, keysym: stroke.keysym, down: stroke.isDown, modifiers: modifiers))]

        case .text(let text):
            return Self.chunks(of: text, maxBytes: LinkLimits.maxTextInputBytes).map { .inputText($0) }

        case .tablet(let point, let pressure, let tiltX, let tiltY):
            guard let at = Self.point(point) else { return [] }
            let p = Float(pressure.isFinite ? min(max(pressure, 0), 1) : 0)
            let tilt = LinkTilt(x: Self.radians(tiltX), y: Self.radians(tiltY))
            // The pen touching the screen is the primary button.
            let buttons: LinkMouseButtons = p > 0 ? .left : []
            return [pointer(at, buttons, modifiers: modifiers, pressure: p, tilt: tilt)]
        }
    }

    // MARK: Pointer

    private mutating func pointer(
        _ at: LinkPoint, _ buttons: LinkMouseButtons, modifiers: LinkModifiers, pressure: Float? = nil, tilt: LinkTilt? = nil
    ) -> LinkMessage {
        lastPointer = at
        lastButtons = buttons
        return .inputPointer(LinkPointerEvent(window: window, point: at, buttons: buttons, modifiers: modifiers, pressure: pressure, tilt: tilt))
    }

    /// A pointer move to where a scroll or gesture happens, only when the helper's pointer is not already there.
    private mutating func positionMessages(_ at: LinkPoint, _ buttons: LinkMouseButtons) -> [LinkMessage] {
        guard lastPointer != at || lastButtons != buttons else { return [] }
        return [pointer(at, buttons, modifiers: modifiers)]
    }

    private mutating func updateModifiers(for stroke: KeyStroke) {
        guard let flag = Self.modifierFlag(forKeysym: stroke.keysym) else { return }
        if stroke.isDown { modifiers.insert(flag) } else { modifiers.remove(flag) }
    }

    // MARK: Conversions

    private static func point(_ point: RemotePoint) -> LinkPoint? {
        guard point.x.isFinite, point.y.isFinite else { return nil }
        let limit = LinkLimits.maxCoordinate
        return LinkPoint(x: min(max(point.x, -limit), limit), y: min(max(point.y, -limit), limit))
    }

    private static func delta(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, -LinkLimits.maxCoordinate), LinkLimits.maxCoordinate)
    }

    private static func radians(_ value: Double) -> Float {
        guard value.isFinite else { return 0 }
        // The wire limit is 2 pi as a Double; the nearest Float above it would be rejected, so stay one step below.
        let limit = Float(2 * Double.pi).nextDown
        return min(max(Float(value), -limit), limit)
    }

    static func buttons(_ buttons: PointerButtons) -> LinkMouseButtons {
        var result: LinkMouseButtons = []
        if buttons.contains(.left) { result.insert(.left) }
        if buttons.contains(.right) { result.insert(.right) }
        if buttons.contains(.middle) { result.insert(.middle) }
        return result
    }

    static func modifiers(_ modifiers: KeyModifiers) -> LinkModifiers {
        var result: LinkModifiers = []
        if modifiers.contains(.shift) { result.insert(.shift) }
        if modifiers.contains(.control) { result.insert(.control) }
        if modifiers.contains(.option) { result.insert(.option) }
        if modifiers.contains(.command) { result.insert(.command) }
        return result
    }

    private static func scrollPhase(_ phase: InputPhase) -> LinkScrollPhase {
        switch phase {
        case .none: .none
        case .began: .began
        case .changed: .changed
        case .ended: .ended
        }
    }

    private static func gesturePhase(_ phase: InputPhase) -> LinkGesturePhase {
        switch phase {
        case .began: .began
        case .ended: .ended
        case .changed, .none: .changed
        }
    }

    private static func gestureKind(_ kind: GestureKind) -> LinkGestureKind {
        switch kind {
        case .magnify: .magnify
        case .rotate: .rotate
        case .smartZoom: .smartMagnify
        }
    }

    // MARK: Keys

    /// Which modifier a keysym (X11 `Shift_L` ... `Meta_R`) stands for.
    static func modifierFlag(forKeysym keysym: UInt32) -> LinkModifiers? {
        switch keysym {
        case 0xFFE1, 0xFFE2: .shift
        case 0xFFE3, 0xFFE4: .control
        case 0xFFE9, 0xFFEA: .option
        case 0xFFE7, 0xFFE8, 0xFFEB, 0xFFEC: .command
        case 0xFFE5: .capsLock
        default: nil
        }
    }

    /// Mac virtual key code (`kVK_*`, ANSI layout) for the keysyms the touch keyboard and accessory bar produce.
    static func macKeyCode(forKeysym keysym: UInt32) -> UInt16? {
        if let code = keysymKeyCodes[keysym] { return code }
        if (0x41...0x5A).contains(keysym) { return keysymKeyCodes[keysym + 0x20] } // capital letters share the key
        return nil
    }

    private static let keysymKeyCodes: [UInt32: UInt16] = {
        var table: [UInt32: UInt16] = [:]
        let ascii: [(Character, UInt16)] = [
            ("a", 0), ("s", 1), ("d", 2), ("f", 3), ("h", 4), ("g", 5), ("z", 6), ("x", 7), ("c", 8), ("v", 9), ("b", 11),
            ("q", 12), ("w", 13), ("e", 14), ("r", 15), ("y", 16), ("t", 17), ("1", 18), ("2", 19), ("3", 20), ("4", 21),
            ("6", 22), ("5", 23), ("=", 24), ("9", 25), ("7", 26), ("-", 27), ("8", 28), ("0", 29), ("]", 30), ("o", 31),
            ("u", 32), ("[", 33), ("i", 34), ("p", 35), ("l", 37), ("j", 38), ("'", 39), ("k", 40), (";", 41), ("\\", 42),
            (",", 43), ("/", 44), ("n", 45), ("m", 46), (".", 47), (" ", 49), ("`", 50),
        ]
        for (character, code) in ascii { table[character.unicodeScalars.first!.value] = code }
        let special: [(UInt32, UInt16)] = [
            (0xFF0D, 36), (0xFF8D, 76), (0xFF09, 48), (0xFF08, 51), (0xFF1B, 53), (0xFFFF, 117),
            (0xFF51, 123), (0xFF52, 126), (0xFF53, 124), (0xFF54, 125), (0xFF50, 115), (0xFF57, 119), (0xFF55, 116), (0xFF56, 121),
            (0xFFE1, 56), (0xFFE2, 60), (0xFFE3, 59), (0xFFE4, 62), (0xFFE9, 58), (0xFFEA, 61), (0xFFE7, 55), (0xFFE8, 54),
            (0xFFEB, 55), (0xFFEC, 54), (0xFFE5, 57),
            (0xFFBE, 122), (0xFFBF, 120), (0xFFC0, 99), (0xFFC1, 118), (0xFFC2, 96), (0xFFC3, 97), (0xFFC4, 98), (0xFFC5, 100),
            (0xFFC6, 101), (0xFFC7, 109), (0xFFC8, 103), (0xFFC9, 111),
        ]
        for (keysym, code) in special { table[keysym] = code }
        return table
    }()

    // MARK: Text

    /// Splits `text` into pieces of at most `maxBytes` UTF-8 bytes. Breaks fall between grapheme clusters, so an emoji with
    /// a skin tone or a Vietnamese letter with combining marks is never cut, and a surrogate pair cannot be split. A single cluster
    /// that is larger than the cap alone (a hostile run of combining marks) is split between Unicode scalars, never inside one.
    public static func chunks(of text: String, maxBytes: Int) -> [String] {
        precondition(maxBytes >= 4, "a cap below one scalar cannot make progress")
        var result: [String] = []
        var current = ""
        var currentBytes = 0
        func flush() {
            if !current.isEmpty { result.append(current) }
            current = ""
            currentBytes = 0
        }
        for character in text {
            let cluster = String(character)
            let size = cluster.utf8.count
            if size > maxBytes {
                flush()
                for scalar in cluster.unicodeScalars {
                    let scalarSize = String(scalar).utf8.count
                    if currentBytes + scalarSize > maxBytes { flush() }
                    current.unicodeScalars.append(scalar)
                    currentBytes += scalarSize
                }
                continue
            }
            if currentBytes + size > maxBytes { flush() }
            current += cluster
            currentBytes += size
        }
        flush()
        return result
    }
}
