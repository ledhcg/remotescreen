import InputKit
import SwiftUI
import UIKit

/// Where the modifier-key sidebar sits (Sidecar style). Persisted between launches.
enum SidebarPosition: String, CaseIterable, Sendable {
    case leading, trailing, hidden

    /// iPad: on the left like Sidecar. iPhone: hidden, because the screen is narrow and the extra-keys bar already has these keys.
    @MainActor static var `default`: SidebarPosition {
        UIDevice.current.userInterfaceIdiom == .pad ? .leading : .hidden
    }
}

/// What a double tap on Apple Pencil (2nd generation, Pro) does on the Mac.
enum PencilDoubleTapAction: String, CaseIterable, Sendable {
    /// Right-click at the cursor (where the pencil last touched): opens the context menu without holding the pencil.
    case secondaryClick
    case toggleKeyboard
    case nothing
}

/// A vertical bar beside the Mac screen, like Sidecar's sidebar: modifier keys ⌘ ⌥ ⌃ ⇧, undo, Escape, keyboard, extra-keys bar,
/// disconnect. It sits **beside** the Mac screen (not on top of it), so the Mac screen shrinks to fit the remaining space.
///
/// Modifier keys: putting a finger down presses on the Mac, lifting releases (hold ⌘ with one hand, tap a file with the other).
/// One quick tap: sticky for the next action. Two taps: locked until tapped again. See `ModifierKeys`.
struct Sidebar: View {
    let controller: SessionController
    let name: String

    static let width: CGFloat = 60

    private static let modifiers: [(StickyModifier, String, String)] = [
        (.command, "⌘", "Command"), (.option, "⌥", "Option"), (.control, "⌃", "Control"), (.shift, "⇧", "Shift"),
    ]

    private var acceptsInput: Bool { controller.isLive && !controller.isViewOnly }

    var body: some View {
        VStack(spacing: 8) {
            ForEach(Self.modifiers, id: \.0) { modifier, symbol, label in
                ModifierKeyButton(
                    symbol: symbol, label: label, state: controller.modifierStates[modifier] ?? .up, isEnabled: acceptsInput,
                    onDown: { controller.modifierTouchDown(modifier) }, onUp: { controller.modifierTouchUp(modifier) }
                )
            }
            Divider().overlay(.white.opacity(0.2)).padding(.vertical, 4)
            SidebarButton(label: String(localized: "Undo"), systemImage: "arrow.uturn.backward") { controller.undo() }
                .disabled(!acceptsInput)
            SidebarButton(label: "Escape", text: "esc") { controller.press(.escape) }
                .disabled(!acceptsInput)
            Spacer(minLength: 8)
            SidebarButton(label: String(localized: "Keyboard"), systemImage: "keyboard", isSelected: controller.isKeyboardVisible) {
                controller.toggleKeyboard()
            }
            .disabled(!acceptsInput)
            SidebarButton(label: String(localized: "Extra keys"), systemImage: "rectangle.grid.1x2", isSelected: controller.isKeyBarVisible) {
                controller.toggleKeyBar()
            }
            .disabled(!acceptsInput)
            SidebarButton(label: String(localized: "Disconnect from \(name)"), systemImage: "xmark", tint: .red) { controller.disconnect() }
        }
        .padding(.vertical, 12)
        .frame(width: Self.width)
        .frame(maxHeight: .infinity)
        .background(Color(white: 0.12).ignoresSafeArea())
    }
}

/// A modifier key on the sidebar. Drawn in SwiftUI, while the touch is received by a `UIControl` (`PressArea`): it needs to know
/// finger-down and finger-up separately, and this touch must not compete with the Mac screen's gesture recognizers on the other hand.
private struct ModifierKeyButton: View {
    let symbol: String
    let label: String
    let state: ModifierState
    let isEnabled: Bool
    let onDown: () -> Void
    let onUp: () -> Void

    private var stateDescription: String {
        switch state {
        case .up: ""
        case .held: String(localized: "Held")
        case .oneShot: String(localized: "Sticky for next action")
        case .locked: String(localized: "Locked")
        }
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(state == .up ? Color.white.opacity(0.1) : state == .held ? Color.blue.opacity(0.75) : Color.blue)
            Text(symbol)
                .font(.title2.weight(.medium))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if state == .locked {
                Image(systemName: "lock.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(5)
            }
        }
        .frame(width: 44, height: 44)
        .opacity(isEnabled ? 1 : 0.35)
        .accessibilityHidden(true)
        .overlay {
            PressArea(
                label: label, value: stateDescription, isSelected: state != .up, isEnabled: isEnabled,
                onDown: onDown, onUp: onUp
            )
        }
    }
}

/// A plain sidebar button (tap to act).
private struct SidebarButton: View {
    let label: String
    var systemImage: String?
    var text: String?
    var isSelected = false
    var tint: Color = .white
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if let systemImage {
                    Image(systemName: systemImage).font(.title3)
                } else if let text {
                    Text(text).font(.callout.weight(.semibold))
                }
            }
            .foregroundStyle(isSelected ? .white : tint)
            .frame(width: 44, height: 40)
            .background(isSelected ? Color.blue : Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// A touch area that reports finger-down and finger-up separately (including drag-out and cancellation).
///
/// Uses a `UIControl` instead of a SwiftUI gesture: `UIControl` touch tracking does not go through gesture recognizers, so a finger
/// holding ⌘ here does not block the other hand's touch on the Mac screen (by default UIKit does not let two recognizers receive at once).
private struct PressArea: UIViewRepresentable {
    let label: String
    let value: String
    let isSelected: Bool
    let isEnabled: Bool
    let onDown: () -> Void
    let onUp: () -> Void

    func makeUIView(context: Context) -> PressControl { PressControl() }

    func updateUIView(_ control: PressControl, context: Context) {
        control.onDown = onDown
        control.onUp = onUp
        control.isEnabled = isEnabled
        control.accessibilityLabel = label
        control.accessibilityValue = value
        var traits: UIAccessibilityTraits = .button
        if isSelected { traits.insert(.selected) }
        if !isEnabled { traits.insert(.notEnabled) }
        control.accessibilityTraits = traits
    }
}

final class PressControl: UIControl {
    var onDown: (() -> Void)?
    var onUp: (() -> Void)?
    private var isPressing = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = true
        backgroundColor = .clear
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        isPressing = true
        onDown?()
        return true
    }

    override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
        finishPress()
    }

    override func cancelTracking(with event: UIEvent?) {
        finishPress()
    }

    /// The sidebar was hidden (or moved sides) while the finger was still down: must still release, otherwise the Mac is left with a stuck key.
    override func willMove(toWindow newWindow: UIWindow?) {
        super.willMove(toWindow: newWindow)
        if newWindow == nil { finishPress() }
    }

    /// VoiceOver activation: a single tap.
    override func accessibilityActivate() -> Bool {
        guard isEnabled else { return false }
        onDown?()
        onUp?()
        return true
    }

    private func finishPress() {
        guard isPressing else { return }
        isPressing = false
        onUp?()
    }
}
