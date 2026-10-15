import Foundation
import RFBKit

/// Việc cần làm với clipboard khi người dùng bấm một phím tắt trên Mac từ xa.
public enum ClipboardIntent: Equatable, Sendable {
    /// ⌘C hoặc ⌘X: Mac sắp có nội dung mới, nên lấy nó về điện thoại sau một lúc.
    case copy
    /// ⌘V: người dùng muốn dán nội dung của **điện thoại**, nên gửi clipboard của điện thoại lên Mac TRƯỚC phím `v`.
    case paste
}

/// Nhận ra ⌘C, ⌘X, ⌘V trong dòng message phím gửi đi, kể cả khi ⌘ và chữ cái đến ở hai lần gửi khác nhau
/// (⌘ dính trên thanh phím phụ, hay bàn phím cứng nhấn ⌘ rồi mới nhấn `v`).
///
/// Thuần logic trên `ClientMessage`, không biết gì về UIKit, nên test được bằng dữ liệu.
public struct ClipboardShortcutDetector: Sendable {
    public struct Match: Equatable, Sendable {
        /// Vị trí trong lô message vừa quan sát của phím chữ nhấn xuống. Gửi clipboard lên phải chèn **trước** vị trí này.
        public var index: Int
        public var intent: ClipboardIntent

        public init(index: Int, intent: ClipboardIntent) {
            self.index = index
            self.intent = intent
        }
    }

    private var commandKeysDown: Set<UInt32> = []

    public init() {}

    /// Chữ cái (thường và hoa, vì Shift có thể đang giữ) ứng với từng phím tắt.
    private static let intents: [UInt32: ClipboardIntent] = [
        0x63: .copy, 0x43: .copy, // c, C
        0x78: .copy, 0x58: .copy, // x, X (cắt cũng đổi clipboard Mac)
        0x76: .paste, 0x56: .paste, // v, V
    ]

    /// Quan sát một lô message sắp gửi, theo đúng thứ tự gửi. Giữ trạng thái ⌘ giữa các lô.
    public mutating func observe(_ messages: [ClientMessage]) -> [Match] {
        var matches: [Match] = []
        for (index, message) in messages.enumerated() {
            guard case .keyEvent(let isDown, let keysym) = message else { continue }
            if keysym == KeysymMapper.commandLeft || keysym == KeysymMapper.commandRight {
                if isDown { commandKeysDown.insert(keysym) } else { commandKeysDown.remove(keysym) }
            } else if isDown, !commandKeysDown.isEmpty, let intent = Self.intents[keysym] {
                matches.append(Match(index: index, intent: intent))
            }
        }
        return matches
    }

    /// Quên trạng thái ⌘ (mất kết nối, nhả mọi phím): tránh một ⌘ "kẹt" biến mọi chữ `c` sau đó thành lệnh chép.
    public mutating func reset() {
        commandKeysDown.removeAll()
    }
}
