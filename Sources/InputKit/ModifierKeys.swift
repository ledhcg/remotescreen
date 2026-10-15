import Foundation
import RFBKit

/// Trạng thái một phím bổ trợ trên sidebar / thanh phím phụ, theo cách của Sidecar.
public enum ModifierState: Sendable, Equatable {
    /// Không nhấn.
    case up
    /// Ngón tay đang đặt trên phím: phím đang nhấn trên Mac, nhả khi nhấc ngón (để ⌘-click, ⇧-click bằng tay kia).
    case held
    /// Đã chạm một lần: phím đang nhấn trên Mac, tự nhả sau thao tác kế tiếp (một phím, một cú nhấp).
    case oneShot
    /// Chạm hai lần: phím giữ nhấn cho tới khi chạm lại.
    case locked
}

/// Máy trạng thái của các phím bổ trợ ⌃ ⌥ ⌘ ⇧. Thuần (thời gian truyền vào), nên test được không cần UI.
///
/// - Đặt ngón: nhấn phím ngay (để giữ-và-nhấp hoạt động).
/// - Nhấc ngón: nếu trong lúc giữ đã có thao tác thì nhả; nếu là một cái chạm ngắn thì thành "dính một lần"; giữ lâu không làm
///   gì thì nhả.
/// - Chạm lần hai trong `doubleTapInterval` khi đang dính: khóa. Chạm khi đang dính (muộn hơn) hoặc đang khóa: nhả.
/// - `actionCompleted()` sau mỗi phím hoặc cú nhấp: nhả các phím đang dính một lần; phím đang giữ thì đánh dấu đã dùng.
public struct ModifierKeys: Sendable, Equatable {
    public static let doubleTapInterval = 0.3
    /// Giữ lâu hơn mức này mà không làm gì thì nhấc ngón là nhả (không biến thành dính).
    public static let tapMaximumDuration = 0.4

    private struct Entry: Sendable, Equatable {
        var modifier: StickyModifier
        var state: ModifierState
        var pressedAt: Double
        var usedWhileHeld = false
        var tappedAt: Double?
        /// Đang khóa và ngón vừa đặt xuống: nhấc lên thì mở khóa.
        var unlocking = false
    }

    /// Các phím không ở trạng thái `.up`, theo thứ tự đã nhấn (nhả theo thứ tự ngược lại).
    private var entries: [Entry] = []

    public init() {}

    public func state(of modifier: StickyModifier) -> ModifierState {
        entries.first { $0.modifier == modifier }?.state ?? .up
    }

    /// Mọi phím đang nhấn trên Mac, theo thứ tự đã nhấn.
    public var active: [StickyModifier] { entries.map(\.modifier) }

    /// Trạng thái các phím không ở `.up`, để giao diện vẽ.
    public var states: [StickyModifier: ModifierState] {
        Dictionary(uniqueKeysWithValues: entries.map { ($0.modifier, $0.state) })
    }

    public mutating func touchDown(_ modifier: StickyModifier, at time: Double) -> [ClientMessage] {
        guard let index = entries.firstIndex(where: { $0.modifier == modifier }) else {
            entries.append(Entry(modifier: modifier, state: .held, pressedAt: time))
            return [.keyEvent(isDown: true, keysym: modifier.keysym)]
        }
        switch entries[index].state {
        case .oneShot:
            if let tapped = entries[index].tappedAt, time - tapped <= Self.doubleTapInterval {
                entries[index].state = .locked // chạm hai lần: khóa (phím vẫn đang nhấn)
                entries[index].tappedAt = nil
            } else {
                entries.remove(at: index) // chạm lại một phím đang dính: bỏ
                return [.keyEvent(isDown: false, keysym: modifier.keysym)]
            }
        case .locked:
            entries[index].unlocking = true
        case .held, .up:
            break
        }
        return []
    }

    public mutating func touchUp(_ modifier: StickyModifier, at time: Double) -> [ClientMessage] {
        guard let index = entries.firstIndex(where: { $0.modifier == modifier }) else { return [] }
        let entry = entries[index]
        switch entry.state {
        case .held:
            if !entry.usedWhileHeld, time - entry.pressedAt <= Self.tapMaximumDuration {
                entries[index].state = .oneShot
                entries[index].tappedAt = time
                return []
            }
            entries.remove(at: index)
            return [.keyEvent(isDown: false, keysym: modifier.keysym)]
        case .locked where entry.unlocking:
            entries.remove(at: index)
            return [.keyEvent(isDown: false, keysym: modifier.keysym)]
        case .locked, .oneShot, .up:
            return []
        }
    }

    /// Một phím thường hoặc một cú nhấp vừa xong: nhả các phím dính một lần, đánh dấu phím đang giữ là đã dùng.
    public mutating func actionCompleted() -> [ClientMessage] {
        var released: [ClientMessage] = []
        for index in entries.indices.reversed() {
            switch entries[index].state {
            case .oneShot:
                released.append(.keyEvent(isDown: false, keysym: entries[index].modifier.keysym))
                entries.remove(at: index)
            case .held:
                entries[index].usedWhileHeld = true
            case .locked, .up:
                break
            }
        }
        return released
    }

    /// Nhả tất cả (mất tiêu điểm, vào nền, ngắt kết nối), theo thứ tự ngược với lúc nhấn.
    public mutating func releaseAll() -> [ClientMessage] {
        defer { entries.removeAll() }
        return entries.reversed().map { .keyEvent(isDown: false, keysym: $0.modifier.keysym) }
    }

    /// Một cái chạm hoàn chỉnh (đặt rồi nhấc ngay), cho thanh phím phụ và bàn phím phần cứng giả lập.
    public mutating func tap(_ modifier: StickyModifier, at time: Double) -> [ClientMessage] {
        touchDown(modifier, at: time) + touchUp(modifier, at: time)
    }
}
