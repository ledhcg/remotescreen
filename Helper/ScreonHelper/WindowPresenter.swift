import AppKit
import SwiftUI

/// Owns the helper's few ordinary windows (setup, pairing). AppKit windows rather than SwiftUI scenes so any part of the app
/// can open them, including at launch, before the menu bar popover has ever been shown.
@MainActor
final class WindowPresenter: NSObject, NSWindowDelegate {
    private var windows: [String: NSWindow] = [:]
    private var closeHandlers: [ObjectIdentifier: () -> Void] = [:]

    func show<Content: View>(id: String, title: String, onClose: (() -> Void)? = nil, @ViewBuilder content: () -> Content) {
        if let existing = windows[id] {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        let controller = NSHostingController(rootView: content())
        let window = NSWindow(contentViewController: controller)
        window.title = title
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        windows[id] = window
        if let onClose { closeHandlers[ObjectIdentifier(window)] = onClose }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func close(id: String) {
        windows[id]?.close()
    }

    func isShowing(id: String) -> Bool { windows[id]?.isVisible ?? false }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        windows = windows.filter { $0.value !== window }
        closeHandlers.removeValue(forKey: ObjectIdentifier(window))?()
    }
}
