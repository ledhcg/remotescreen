import Foundation
import RFBKit

/// Phím có trên thanh phím phụ nhưng không có trên bàn phím ảo của iOS.
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

    /// Nhấn rồi nhả.
    public var tap: [ClientMessage] {
        [.keyEvent(isDown: true, keysym: keysym), .keyEvent(isDown: false, keysym: keysym)]
    }
}

/// Phím bổ trợ trên sidebar và thanh phím phụ. Trạng thái (giữ, dính một lần, khóa) nằm ở `ModifierKeys`.
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
}
