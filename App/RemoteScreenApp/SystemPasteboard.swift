import SessionKit
import UIKit
import UniformTypeIdentifiers

/// Bảng clipboard thật của iOS. Chỉ `string` (đọc) có thể hiện hộp thoại cho phép dán; `ClipboardBridge` đọc nó ít nhất có thể.
@MainActor
final class SystemPasteboard: PasteboardAccess {
    var changeCount: Int { UIPasteboard.general.changeCount }
    var hasStrings: Bool { UIPasteboard.general.hasStrings }

    var string: String? {
        get { UIPasteboard.general.string }
        set { UIPasteboard.general.string = newValue }
    }

    /// Chỉ trên máy này (không đồng bộ Universal Clipboard sang thiết bị khác) và tự xóa sau `seconds`.
    func writeSensitive(_ text: String, expiresAfter seconds: TimeInterval) {
        UIPasteboard.general.setItems(
            [[UTType.utf8PlainText.identifier: text]],
            options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(seconds)]
        )
    }
}
