import InputKit
import SwiftUI
import UIKit

/// Chỗ đặt sidebar phím bổ trợ (kiểu Sidecar). Lưu lại giữa các lần mở app.
enum SidebarPosition: String, CaseIterable, Sendable {
    case leading, trailing, hidden

    /// iPad: bên trái như Sidecar. iPhone: ẩn, vì màn hình hẹp và thanh phím phụ đã có các phím này.
    @MainActor static var `default`: SidebarPosition {
        UIDevice.current.userInterfaceIdiom == .pad ? .leading : .hidden
    }
}

/// Chạm hai lần lên Apple Pencil (thế hệ 2, Pro) làm gì trên Mac.
enum PencilDoubleTapAction: String, CaseIterable, Sendable {
    /// Nhấp phải tại chỗ con trỏ (chỗ bút vừa chạm): mở menu ngữ cảnh mà không phải giữ bút.
    case secondaryClick
    case toggleKeyboard
    case nothing
}

/// Thanh dọc cạnh màn hình Mac, như sidebar của Sidecar: phím bổ trợ ⌘ ⌥ ⌃ ⇧, hoàn tác, Escape, bàn phím, thanh phím phụ,
/// ngắt kết nối. Nằm **cạnh** màn hình Mac (không đè lên), nên màn hình Mac co lại cho vừa phần còn lại.
///
/// Phím bổ trợ: đặt ngón là nhấn trên Mac, nhấc ra là nhả (giữ ⌘ bằng một tay, chạm file bằng tay kia). Chạm nhanh một lần: dính
/// cho thao tác kế tiếp. Chạm hai lần: khóa tới khi chạm lại. Xem `ModifierKeys`.
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
            SidebarButton(label: "Hoàn tác", systemImage: "arrow.uturn.backward") { controller.undo() }
                .disabled(!acceptsInput)
            SidebarButton(label: "Escape", text: "esc") { controller.press(.escape) }
                .disabled(!acceptsInput)
            Spacer(minLength: 8)
            SidebarButton(label: "Bàn phím", systemImage: "keyboard", isSelected: controller.isKeyboardVisible) {
                controller.toggleKeyboard()
            }
            .disabled(!acceptsInput)
            SidebarButton(label: "Phím phụ", systemImage: "rectangle.grid.1x2", isSelected: controller.isKeyBarVisible) {
                controller.toggleKeyBar()
            }
            .disabled(!acceptsInput)
            SidebarButton(label: "Ngắt kết nối với \(name)", systemImage: "xmark", tint: .red) { controller.disconnect() }
        }
        .padding(.vertical, 12)
        .frame(width: Self.width)
        .frame(maxHeight: .infinity)
        .background(Color(white: 0.12).ignoresSafeArea())
    }
}

/// Một phím bổ trợ trên sidebar. Hình vẽ bằng SwiftUI, còn cú chạm do một `UIControl` nhận (`PressArea`): cần biết lúc đặt
/// ngón và lúc nhấc ngón riêng rẽ, và cú chạm này phải không tranh với bộ nhận diện cử chỉ của màn hình Mac ở tay kia.
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
        case .held: "Đang giữ"
        case .oneShot: "Dính cho thao tác kế tiếp"
        case .locked: "Đang khóa"
        }
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            RoundedRectangle(cornerRadius: 10)
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

/// Nút thường trên sidebar (chạm là làm).
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
            .background(isSelected ? Color.blue : Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Vùng chạm báo riêng lúc đặt ngón và lúc nhấc ngón (kể cả kéo ra ngoài hay bị hủy).
///
/// Dùng `UIControl` thay cho cử chỉ SwiftUI: theo dõi chạm của `UIControl` không đi qua bộ nhận diện cử chỉ, nên ngón đang giữ ⌘
/// ở đây không chặn cú chạm của tay kia trên màn hình Mac (mặc định UIKit không cho hai bộ nhận diện cùng nhận một lúc).
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

    /// Sidebar bị ẩn (hay đổi bên) trong lúc ngón còn đặt: vẫn phải nhả, không thì Mac bị kẹt phím.
    override func willMove(toWindow newWindow: UIWindow?) {
        super.willMove(toWindow: newWindow)
        if newWindow == nil { finishPress() }
    }

    /// VoiceOver kích hoạt: một cái chạm.
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
