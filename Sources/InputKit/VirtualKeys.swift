import Foundation

/// Keys that are on the accessory bar but not on the iOS on-screen keyboard.
public enum VirtualKey: Sendable, Equatable, CaseIterable {
    case escape, tab
    case left, up, right, down
    case home, end, pageUp, pageDown
    case forwardDelete

    /// Keysym X11 (`keysymdef.h`).
    public var keysym: UInt32 {
        switch self {
        case .escape: 0xFF1B
        case .tab: 0xFF09
        case .left: 0xFF51
        case .up: 0xFF52
        case .right: 0xFF53
        case .down: 0xFF54
        case .home: 0xFF50
        case .end: 0xFF57
        case .pageUp: 0xFF55
        case .pageDown: 0xFF56
        case .forwardDelete: 0xFFFF
        }
    }

    /// Mac virtual key code (`kVK_*`).
    public var macKeyCode: UInt16 {
        switch self {
        case .escape: 53
        case .tab: 48
        case .left: 123
        case .up: 126
        case .right: 124
        case .down: 125
        case .home: 115
        case .end: 119
        case .pageUp: 116
        case .pageDown: 121
        case .forwardDelete: 117
        }
    }

    /// Press then release.
    public var tap: [InputIntent] { InputIntent.tap(keysym, macKeyCode: macKeyCode) }
}

/// Modifier keys on the sidebar and accessory bar. Their state (held, latched once, locked) lives in `ModifierKeys`.
public enum StickyModifier: Sendable, Equatable, CaseIterable {
    case control, option, command, shift

    public var keysym: UInt32 {
        switch self {
        case .control: 0xFFE3
        case .option: 0xFFE9
        case .command: KeysymMapper.commandLeft
        case .shift: 0xFFE1
        }
    }

    /// Mac virtual key code (`kVK_Control`, `kVK_Option`, `kVK_Command`, `kVK_Shift`).
    public var macKeyCode: UInt16 {
        switch self {
        case .control: 59
        case .option: 58
        case .command: 55
        case .shift: 56
        }
    }
}
