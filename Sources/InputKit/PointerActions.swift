import RFBKit

/// Recognizes mouse-action milestones in the stream of outgoing messages.
public enum PointerActions {
    /// `true` if at some point the mouse buttons (left, middle, right; not counting wheel buttons 4-7) went from pressed to all released, meaning a
    /// click or a drag has just finished. `previousButtons` carries state across calls.
    public static func completesAButtonAction(_ messages: [ClientMessage], previousButtons: inout UInt8) -> Bool {
        var completed = false
        for case .pointerEvent(let buttons, _, _) in messages {
            let pressed = buttons & 0x07
            if previousButtons != 0, pressed == 0 { completed = true }
            previousButtons = pressed
        }
        return completed
    }
}
