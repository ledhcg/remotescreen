import InputKit
import RemoteDisplay
import SessionKit
import SwiftUI

/// The options of a Screen Sharing session as a bottom sheet (the "…" button of the toolbar): icon and title on the left, the current value
/// on the right, a menu of the other values on tap, and a red Disconnect button at the foot.
struct SessionSettingsSheet: View {
    let controller: SessionController
    let name: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        SettingsSheet(
            title: "Options", destructiveTitle: "Disconnect",
            destructiveAction: { dismiss(); controller.disconnect() }
        ) {
            SettingsGroup(title: "Control") {
                SettingsMenuRow(
                    systemImage: "cursorarrow.click.2", title: "Mode",
                    selection: Binding(get: { controller.isViewOnly }, set: { controller.setViewOnly($0) }),
                    options: [
                        SettingsOption(value: false, title: "Take control", systemImage: "cursorarrow.click.2"),
                        SettingsOption(value: true, title: "View only", systemImage: "eye"),
                    ])
                SettingsMenuRow(
                    systemImage: "hand.point.up.left", title: "Touch style",
                    selection: Binding(get: { controller.touchMode }, set: { controller.setTouchMode($0) }),
                    options: [
                        SettingsOption(value: TouchMode.directTouch, title: "Direct touch", systemImage: "hand.point.up.left"),
                        SettingsOption(value: TouchMode.trackpad, title: "Trackpad", systemImage: "rectangle.and.hand.point.up.left"),
                    ])
            }
            SettingsGroup(title: "Display") {
                SettingsMenuRow(
                    systemImage: "arrow.down.right.and.arrow.up.left", title: "Display",
                    selection: Binding(get: { controller.displayMode }, set: { controller.setDisplayMode($0) }),
                    options: [
                        SettingsOption(value: DisplayMode.fit, title: "Fit to screen", systemImage: "arrow.down.right.and.arrow.up.left"),
                        SettingsOption(value: DisplayMode.fill, title: "Fill screen", systemImage: "arrow.up.left.and.arrow.down.right"),
                        SettingsOption(value: DisplayMode.native, title: "Native pixels (1:1)", systemImage: "1.square"),
                        SettingsOption(value: DisplayMode.device, title: "Match device resolution", systemImage: "rectangle.on.rectangle"),
                    ])
                SettingsMenuRow(
                    systemImage: "sidebar.left", title: "Sidebar",
                    selection: Binding(get: { controller.sidebarPosition }, set: { controller.setSidebarPosition($0) }),
                    options: [
                        SettingsOption(value: SidebarPosition.leading, title: "Sidebar on the left", systemImage: "sidebar.left"),
                        SettingsOption(value: SidebarPosition.trailing, title: "Sidebar on the right", systemImage: "sidebar.right"),
                        SettingsOption(value: SidebarPosition.hidden, title: "Hide sidebar", systemImage: "rectangle"),
                    ])
                SettingsMenuRow(
                    systemImage: "wand.and.stars", title: "Picture quality",
                    selection: Binding(get: { controller.qualityMode }, set: { controller.setQualityMode($0) }),
                    options: [
                        SettingsOption(value: QualityMode.adaptive, title: "Automatic", systemImage: "wand.and.stars"),
                        SettingsOption(value: QualityMode.bestQuality, title: "Best quality", systemImage: "sparkles.tv"),
                        SettingsOption(value: QualityMode.bestPerformance, title: "Best performance", systemImage: "bolt"),
                    ])
                SettingsToggleRow(
                    systemImage: "gauge.with.dots.needle.33percent", title: "Show stream statistics",
                    isOn: Binding(get: { controller.isStatsVisible }, set: { controller.setStatsVisible($0) }))
            }
            SettingsGroup(title: "Gestures on Mac") {
                SettingsToggleRow(
                    systemImage: "hand.draw", title: "Smooth scrolling",
                    isOn: Binding(get: { controller.smoothScroll }, set: { controller.setSmoothScroll($0) }),
                    isEnabled: controller.isAppleServer)
                SettingsMenuRow(
                    systemImage: "hand.pinch", title: "Pinch and rotate",
                    selection: Binding(get: { controller.pinchSendsToMac }, set: { controller.setPinchSendsToMac($0) }),
                    options: [
                        SettingsOption(value: false, title: "Zoom on iPad"),
                        SettingsOption(value: true, title: "Send to Mac"),
                    ],
                    isEnabled: controller.isAppleServer)
                if UIDevice.current.userInterfaceIdiom == .pad {
                    SettingsMenuRow(
                        systemImage: "applepencil", title: "Pencil double tap",
                        selection: Binding(get: { controller.pencilDoubleTapAction }, set: { controller.setPencilDoubleTapAction($0) }),
                        options: [
                            SettingsOption(value: PencilDoubleTapAction.secondaryClick, title: "Right-click"),
                            SettingsOption(value: PencilDoubleTapAction.toggleKeyboard, title: "Show/hide keyboard"),
                            SettingsOption(value: PencilDoubleTapAction.nothing, title: "Do nothing"),
                        ])
                    SettingsToggleRow(
                        systemImage: "hand.draw", title: "Fingers scroll only with pencil",
                        isOn: Binding(get: { controller.fingersOnlyScrollWithPencil }, set: { controller.setFingersOnlyScrollWithPencil($0) }))
                }
            }
            if !controller.isAppleServer {
                Text("Only available with a Mac (macOS Screen Sharing)")
                    .font(.footnote)
                    .foregroundStyle(Theme.onChromeSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.top, -12)
            }
            SettingsGroup(title: "Cursor") {
                SettingsToggleRow(
                    systemImage: "cursorarrow", title: "Show Mac cursor",
                    isOn: Binding(get: { controller.isRemoteCursorVisible }, set: { controller.setRemoteCursorVisible($0) }))
                SettingsMenuRow(
                    systemImage: "cursorarrow.rays", title: "Cursor style",
                    selection: Binding(get: { controller.cursorStyle }, set: { controller.setCursorStyle($0) }),
                    options: CursorStyle.allCases.map { SettingsOption(value: $0, title: $0.title) },
                    isEnabled: controller.isRemoteCursorVisible && controller.drawsCursorLocally)
            }
            if !controller.drawsCursorLocally {
                Text("In Best performance the Mac draws its own cursor")
                    .font(.footnote)
                    .foregroundStyle(Theme.onChromeSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.top, -12)
            }
            SettingsGroup(title: "Clipboard") {
                SettingsMenuRow(
                    systemImage: "doc.on.clipboard", title: "Sync",
                    selection: Binding(get: { controller.clipboard.mode }, set: { controller.clipboard.mode = $0 }),
                    options: [
                        SettingsOption(value: ClipboardBridge.Mode.manual, title: "Manual"),
                        SettingsOption(value: ClipboardBridge.Mode.shared, title: "Automatic (⌘C, ⌘V)"),
                    ])
                SettingsActionRow(systemImage: "arrow.down.doc", title: "Get clipboard from Mac") {
                    controller.clipboard.requestFromMac()
                    dismiss()
                }
            }
        }
    }
}
