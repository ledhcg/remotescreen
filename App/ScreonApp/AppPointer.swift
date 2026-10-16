import RemoteDisplay
import SwiftUI
import UIKit

/// Replaces the iPadOS pointer (the round dot) with one of Screon's arrows across the app's own screens.
///
/// A pointer interaction sits on every app window, so it applies wherever no deeper view has its own: buttons and rows keep
/// their system hover effect, and the Mac screen keeps hiding the iPad pointer (`ScreonView`, `AppWindowView`) because it draws
/// the Mac's cursor itself. Separate from `CursorStylePreference`, which styles the cursor drawn on the Mac screen.
@MainActor
final class AppPointer: NSObject, UIPointerInteractionDelegate {
    static let shared = AppPointer()
    static let key = "appPointerStyle"

    /// `.mac` means the system pointer.
    var style: CursorStyle = UserDefaults.standard.string(forKey: key).flatMap(CursorStyle.init(rawValue:)) ?? .mac {
        didSet {
            guard style != oldValue else { return }
            UserDefaults.standard.set(style.rawValue, forKey: Self.key)
            for interaction in interactions.allObjects { interaction.invalidate() }
        }
    }

    private let interactions = NSHashTable<UIPointerInteraction>.weakObjects()
    private var observer: NSObjectProtocol?

    /// Starts adding the interaction to each app window as it appears. iPad only: iPhone has no pointer.
    func install() {
        guard UIDevice.current.userInterfaceIdiom == .pad, observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: UIWindow.didBecomeVisibleNotification, object: nil, queue: .main) { note in
            guard let window = note.object as? UIWindow else { return }
            MainActor.assumeIsolated { AppPointer.shared.attach(to: window) }
        }
    }

    private func attach(to window: UIWindow) {
        // Normal-level windows only: not the keyboard's or the system's own windows.
        guard window.windowLevel == .normal, !window.interactions.contains(where: { ($0 as? UIPointerInteraction)?.delegate === self }) else { return }
        let interaction = UIPointerInteraction(delegate: self)
        window.addInteraction(interaction)
        interactions.add(interaction)
    }

    func pointerInteraction(
        _ interaction: UIPointerInteraction, regionFor request: UIPointerRegionRequest, defaultRegion: UIPointerRegion
    ) -> UIPointerRegion? {
        style == .mac ? nil : defaultRegion
    }

    func pointerInteraction(_ interaction: UIPointerInteraction, styleFor region: UIPointerRegion) -> UIPointerStyle? {
        // The path has the tip at (0, 0), which is where the pointer is.
        guard let path = style.pointerPath else { return nil }
        return UIPointerStyle(shape: .path(UIBezierPath(cgPath: path)))
    }
}

/// The pointer picker, for the computer list's toolbar (iPad only).
struct AppPointerMenu: View {
    @State private var style = AppPointer.shared.style

    var body: some View {
        Menu {
            Picker("Pointer", selection: $style) {
                ForEach(CursorStyle.allCases, id: \.self) { style in
                    Label { Text(style == .mac ? "iPad pointer" : style.title) } icon: { style == .mac ? Image(systemName: "circle.fill") : style.menuIcon }.tag(style)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Label("Pointer", systemImage: "cursorarrow")
        }
        .onChange(of: style) { _, style in AppPointer.shared.style = style }
    }
}
