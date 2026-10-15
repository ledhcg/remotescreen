import SessionKit
import UIKit
import UniformTypeIdentifiers

/// The real iOS pasteboard. Only reading `string` can show the paste-permission prompt; `ClipboardBridge` reads it as little as possible.
@MainActor
final class SystemPasteboard: PasteboardAccess {
    var changeCount: Int { UIPasteboard.general.changeCount }
    var hasStrings: Bool { UIPasteboard.general.hasStrings }

    var string: String? {
        get { UIPasteboard.general.string }
        set { UIPasteboard.general.string = newValue }
    }

    /// Local to this device (not synced to other devices via Universal Clipboard) and cleared automatically after `seconds`.
    func writeSensitive(_ text: String, expiresAfter seconds: TimeInterval) {
        UIPasteboard.general.setItems(
            [[UTType.utf8PlainText.identifier: text]],
            options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(seconds)]
        )
    }
}
