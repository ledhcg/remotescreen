import SwiftUI

/// The look of Screon, in one place. Every colour, radius and control style the app draws comes from here; see
/// `.claude/rules/design-system.md` for the rules behind it.
///
/// Two layers:
/// - **Chrome**: controls floating over a remote screen (toolbar, keys, window buttons, banners, cards, sheets of a session). Always dark
///   and opaque enough to read over any picture, whatever the device's appearance.
/// - **Screens**: the computer list, settings and pairing. These follow the system appearance and use system colours.
enum Theme {
    // MARK: Colour

    /// The one accent: selection, the primary action, text buttons. Icons are never accent-coloured at rest.
    ///
    /// It is the system blue, which is also the app's default tint, so it is **not** set as a global `.tint`: a tint set on the app
    /// reaches the icons of system menus and paints them blue, and a menu's icons are monochrome.
    static let accent = Color(.systemBlue)

    /// A control at rest (round button, key).
    static let chrome = Color(white: 0.18)
    /// A control that is pressed, or a key cap.
    static let chromeRaised = Color(white: 0.26)
    /// A bar or card over the remote screen.
    static let chromeBar = Color(white: 0.10).opacity(0.96)
    /// A bottom sheet of a session: lighter than the black behind it, so its edge is visible.
    static let sheet = Color(white: 0.15)
    /// The 1 pt edge of every chrome surface.
    static let hairline = Color.white.opacity(0.16)
    /// Icon and text colour on chrome.
    static let onChrome = Color.white
    static let onChromeSecondary = Color.white.opacity(0.62)
    static let destructive = Color(red: 1.0, green: 0.35, blue: 0.33)
    /// A destructive control filled with colour (disconnect): deep enough for white text and a white icon to read on it.
    static let destructiveFill = Color(red: 0.84, green: 0.16, blue: 0.15)
    static let online = Color(red: 0.19, green: 0.82, blue: 0.35)

    // MARK: Shape

    enum Radius {
        /// Cards and banners that can wrap onto two lines.
        static let card: CGFloat = 18
        /// Buttons that are not round, and rows inside a card.
        static let control: CGFloat = 12
        /// Keys.
        static let key: CGFloat = 10
        /// A bottom sheet.
        static let sheet: CGFloat = 28
        /// The tile of a computer or an app icon, as a fraction of its side: the same curve at every size.
        static let tileRatio: CGFloat = 0.24
    }

    enum Size {
        /// The smallest thing a finger has to hit.
        static let hit: CGFloat = 44
        /// A round button.
        static let round: CGFloat = 44
        static let key = CGSize(width: 44, height: 40)
        /// A quick action on a row of the computer list.
        static let quickAction: CGFloat = 40
    }

    // MARK: Computer tiles

    /// The tile of a computer: blue for the local network, black for Tailscale.
    static func tile(for network: NetworkSourceStyle) -> LinearGradient {
        switch network {
        case .lan: LinearGradient(colors: [.blue, .indigo], startPoint: .top, endPoint: .bottom)
        case .tailscale: LinearGradient(colors: [Color(white: 0.16), .black], startPoint: .top, endPoint: .bottom)
        }
    }
}

/// The two looks of a computer tile. A separate type so the design system does not import ConnectionKit.
enum NetworkSourceStyle {
    case lan, tailscale
}

// MARK: - Surfaces

extension View {
    /// A bar, banner or card over a remote screen: dark, near opaque, with a hairline edge, in any appearance.
    func chromeSurface<S: InsettableShape>(_ shape: S) -> some View {
        background(Theme.chromeBar, in: shape)
            .overlay(shape.strokeBorder(Theme.hairline, lineWidth: 1))
            .environment(\.colorScheme, .dark)
    }

    /// A card (connecting, a window's status): `Theme.Radius.card`, continuous.
    func chromeCard() -> some View {
        chromeSurface(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }

    /// A banner whose text can wrap: a rounded rectangle, because the ends of a capsule would cut into the second line.
    func chromeBanner() -> some View {
        chromeSurface(RoundedRectangle(cornerRadius: Theme.Radius.control + 4, style: .continuous))
    }

    /// A pill that holds one line of controls (the session toolbar, the keys bar).
    func chromePill() -> some View {
        chromeSurface(Capsule())
    }

    /// A bottom sheet over a session: an opaque surface lighter than the screen behind it, a visible grabber, large corners, dark.
    func chromeSheet() -> some View {
        presentationBackground(Theme.sheet)
            .presentationCornerRadius(Theme.Radius.sheet)
            .presentationDragIndicator(.visible)
            .preferredColorScheme(.dark)
    }

    /// A list inside a chrome sheet: the sheet's surface, and rows one step lighter so each row can be told apart.
    func chromeList() -> some View {
        scrollContentBackground(.hidden)
            .background(Theme.sheet)
            .listRowBackground(Theme.chrome)
    }
}

// MARK: - Haptics

/// Haptic feedback: every control that can be touched answers with one, so a touch is felt even when the Mac is slow to react.
/// Button styles add it themselves (`pressHaptic`), so a button that uses them needs nothing more; a control with its own touch
/// handling (a `UIControl`, a toggle, a picker) calls these.
@MainActor
enum Haptics {
    /// A press: a button, a key, a tab.
    static func tap() { UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.8) }
    /// A choice changed: a picker, a toggle, a segment.
    static func selection() { UISelectionFeedbackGenerator().selectionChanged() }
    /// Something finished well (a paired computer, a copied value).
    static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    /// Something needs care (a destructive action is about to run).
    static func warning() { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
}

extension View {
    /// A light tap at the moment a button goes down (not when it is released), as the system's own controls do.
    func pressHaptic(_ isPressed: Bool) -> some View {
        sensoryFeedback(.impact(weight: .light, intensity: 0.8), trigger: isPressed) { _, pressed in pressed }
    }

    /// For a button in a system style (`.bordered`, `.borderedProminent`), which cannot add the haptic itself: a light tap on each tap.
    func tapHaptic() -> some View { modifier(TapHaptic()) }

    /// A tick when the value of a picker, toggle or segment changes.
    func selectionHaptic<V: Equatable>(_ value: V) -> some View {
        sensoryFeedback(.selection, trigger: value)
    }
}

private struct TapHaptic: ViewModifier {
    @State private var taps = 0

    func body(content: Content) -> some View {
        content
            .simultaneousGesture(TapGesture().onEnded { taps += 1 })
            .sensoryFeedback(.impact(weight: .light, intensity: 0.8), trigger: taps)
    }
}

/// `.plain` (the label as drawn, no tint) plus the press haptic: for rows and tabs that draw themselves.
struct HapticPlainStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.6 : 1)
            .pressHaptic(configuration.isPressed)
    }
}

// MARK: - Controls

/// A round button of the chrome (40 pt of icon in a 44 pt circle): white icon on a dark disc, accent fill while selected, red fill (still
/// a white icon) when it is destructive.
/// Used for buttons and, through `ChromeRoundLabel`, for menus.
struct ChromeRoundButtonStyle: ButtonStyle {
    var isSelected = false
    var isDestructive = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 18, weight: .medium))
            .foregroundStyle(Theme.onChrome)
            .frame(width: Theme.Size.round, height: Theme.Size.round)
            .background(fill(pressed: configuration.isPressed), in: Circle())
            .overlay(Circle().strokeBorder(Theme.hairline, lineWidth: 1))
            .contentShape(Circle())
            .environment(\.colorScheme, .dark)
            .pressHaptic(configuration.isPressed)
    }

    private func fill(pressed: Bool) -> Color {
        if isDestructive { return pressed ? Theme.destructiveFill.opacity(0.8) : Theme.destructiveFill }
        if isSelected { return Theme.accent }
        return pressed ? Theme.chromeRaised : Theme.chrome
    }
}

/// The look of `ChromeRoundButtonStyle` for something that is not a `Button` (a `Menu` label).
struct ChromeRoundLabel: View {
    let systemImage: String
    var isSelected = false

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 18, weight: .medium))
            .foregroundStyle(Theme.onChrome)
            .frame(width: Theme.Size.round, height: Theme.Size.round)
            .background(isSelected ? Theme.accent : Theme.chrome, in: Circle())
            .overlay(Circle().strokeBorder(Theme.hairline, lineWidth: 1))
            .contentShape(Circle())
            .environment(\.colorScheme, .dark)
    }
}

/// A key of the extra-keys bar and of the sidebar: one shape, one size (44 × 40), one fill, white label, accent fill while it is held or
/// on. No key is wider than another whatever its label: a word (esc, home) is set smaller by `KeyCapText` to fit.
struct KeyCapStyle: ButtonStyle {
    var isSelected = false
    var isDestructive = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(Theme.onChrome)
            .frame(width: Theme.Size.key.width, height: Theme.Size.key.height)
            .background(fill(pressed: configuration.isPressed), in: RoundedRectangle(cornerRadius: Theme.Radius.key, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.key, style: .continuous))
            .environment(\.colorScheme, .dark)
            .pressHaptic(configuration.isPressed)
    }

    private func fill(pressed: Bool) -> Color {
        if isDestructive { return pressed ? Theme.destructiveFill.opacity(0.8) : Theme.destructiveFill }
        if isSelected { return Theme.accent }
        return pressed ? Theme.chromeRaised.opacity(0.7) : Theme.chromeRaised
    }
}

/// The text of a key: a single glyph (⌘ ← ⇧) at the full size, a word (esc, home, pg↑) smaller, so both sit in the same 44 pt key.
struct KeyCapText: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: text.count > 1 ? 13 : 18, weight: .semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
    }
}

/// The look of `KeyCapStyle` for something that is not a `Button` (a `Menu` label): the same cap, same size, same icon size.
struct KeyCapLabel: View {
    let systemImage: String
    var isSelected = false

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(Theme.onChrome)
            .frame(width: Theme.Size.key.width, height: Theme.Size.key.height)
            .background(isSelected ? Theme.accent : Theme.chromeRaised, in: RoundedRectangle(cornerRadius: Theme.Radius.key, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.key, style: .continuous))
            .environment(\.colorScheme, .dark)
    }
}

/// A quick action on a row of the computer list: a round button that stays quiet until it is needed.
struct QuickActionStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 17, weight: .medium))
            .foregroundStyle(.primary)
            .frame(width: Theme.Size.quickAction, height: Theme.Size.quickAction)
            .background(configuration.isPressed ? Color(.tertiarySystemFill) : Color(.secondarySystemFill), in: Circle())
            .frame(width: Theme.Size.hit, height: Theme.Size.hit) // the hit area is 44 pt even though the disc is 40
            .contentShape(Rectangle())
            .pressHaptic(configuration.isPressed)
    }
}

// MARK: - Computer tile

/// The tile of a computer: a rounded square (blue for the local network, black for Tailscale) with a dot while the computer is available.
struct ComputerTile: View {
    var size: CGFloat = 40
    var network: NetworkSourceStyle = .lan
    var isOnline = false

    var body: some View {
        RoundedRectangle(cornerRadius: size * Theme.Radius.tileRatio, style: .continuous)
            .fill(Theme.tile(for: network))
            .overlay(
                RoundedRectangle(cornerRadius: size * Theme.Radius.tileRatio, style: .continuous)
                    .strokeBorder(.white.opacity(network == .tailscale ? 0.22 : 0.0), lineWidth: 1) // black on a dark list needs an edge
            )
            .frame(width: size, height: size)
            .overlay { Image(systemName: "desktopcomputer").font(.system(size: size * 0.5)).foregroundStyle(.white) }
            .overlay(alignment: .bottomTrailing) {
                if isOnline {
                    Circle()
                        .fill(Theme.online)
                        .frame(width: size * 0.3, height: size * 0.3)
                        .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 2))
                        .offset(x: 3, y: 3)
                        .accessibilityHidden(true)
                }
            }
            .accessibilityHidden(true)
    }
}

// MARK: - Settings sheet

/// One choice of a `SettingsMenuRow`.
struct SettingsOption<Value: Hashable>: Identifiable {
    let value: Value
    let title: LocalizedStringKey
    var systemImage: String?

    var id: Value { value }
}

/// A bottom sheet of settings over a session: a title, rows grouped in cards, and a full-width red button at the foot. Rows have the icon
/// and title on the left and the current value on the right; tapping a value opens a menu of the other values.
struct SettingsSheet<Content: View>: View {
    let title: LocalizedStringKey
    let destructiveTitle: LocalizedStringKey
    var destructiveImage = "xmark.circle"
    var destructiveIdentifier: String?
    let destructiveAction: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            Text(title)
                .font(.headline)
                .foregroundStyle(Theme.onChrome)
                .frame(maxWidth: .infinity)
                .padding(.top, 22)
                .padding(.bottom, 12)
            ScrollView {
                VStack(spacing: 20) { content }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
            }
            DestructiveWideButton(title: destructiveTitle, systemImage: destructiveImage, action: destructiveAction)
                .modifier(OptionalIdentifier(identifier: destructiveIdentifier))
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.sheet)
        .chromeSheet()
    }
}

/// An accessibility identifier only when there is one: an empty one would replace the label that UI tests look a button up by.
private struct OptionalIdentifier: ViewModifier {
    let identifier: String?

    @ViewBuilder func body(content: Content) -> some View {
        if let identifier { content.accessibilityIdentifier(identifier) } else { content }
    }
}

/// A titled card of rows, with a hairline between rows.
struct SettingsGroup<Content: View>: View {
    var title: LocalizedStringKey?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title {
                Text(title)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.onChromeSecondary)
                    .textCase(.uppercase)
                    .padding(.horizontal, 16)
            }
            VStack(spacing: 0) {
                Group(subviews: content) { rows in
                    ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                        if index > 0 { Divider().overlay(Theme.hairline).padding(.leading, 56) }
                        row
                    }
                }
            }
            .background(Theme.chrome, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
        }
    }
}

/// A row: icon and title on the left, whatever `trailing` draws on the right. At least 52 pt tall, so every row is a 44 pt target.
struct SettingsRow<Trailing: View>: View {
    let systemImage: String
    let title: LocalizedStringKey
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Theme.onChrome)
                .frame(width: 28)
                .accessibilityHidden(true)
            Text(title)
                .font(.body)
                .foregroundStyle(Theme.onChrome)
                .frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 52)
    }
}

/// A row whose value is one of several: the current one is shown on the right, and tapping it opens a menu of the others.
struct SettingsMenuRow<Value: Hashable>: View {
    let systemImage: String
    let title: LocalizedStringKey
    @Binding var selection: Value
    let options: [SettingsOption<Value>]
    var isEnabled = true

    private var current: LocalizedStringKey { options.first { $0.value == selection }?.title ?? "" }

    var body: some View {
        SettingsRow(systemImage: systemImage, title: title) {
            Menu {
                Picker(selection: $selection) {
                    ForEach(options) { option in
                        if let image = option.systemImage {
                            Label(option.title, systemImage: image).tag(option.value)
                        } else {
                            Text(option.title).tag(option.value)
                        }
                    }
                } label: { Text(title) }
            } label: {
                HStack(spacing: 6) {
                    Text(current).lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 11, weight: .semibold))
                }
                .font(.body)
                .foregroundStyle(Theme.onChromeSecondary)
                .frame(minHeight: Theme.Size.hit)
                .contentShape(Rectangle())
            }
            .menuOrder(.fixed)
            .accessibilityLabel(title)
            .accessibilityValue(current)
        }
        .opacity(isEnabled ? 1 : 0.4)
        .disabled(!isEnabled)
        .selectionHaptic(selection)
    }
}

/// A row with an on/off switch.
struct SettingsToggleRow: View {
    let systemImage: String
    let title: LocalizedStringKey
    @Binding var isOn: Bool
    var isEnabled = true

    var body: some View {
        SettingsRow(systemImage: systemImage, title: title) {
            Toggle(isOn: $isOn) { Text(title) }
                .labelsHidden()
                .tint(Theme.accent) // on the switch only: a tint higher up would reach the icons of every menu inside
        }
        .opacity(isEnabled ? 1 : 0.4)
        .disabled(!isEnabled)
        .selectionHaptic(isOn)
    }
}

/// A row that does something when tapped, with an optional short note on the right.
struct SettingsActionRow: View {
    let systemImage: String
    let title: LocalizedStringKey
    var detail: String?
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            SettingsRow(systemImage: systemImage, title: title) {
                if let detail { Text(detail).font(.body).foregroundStyle(Theme.onChromeSecondary) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(SettingsRowPressStyle())
        .opacity(isEnabled ? 1 : 0.4)
        .disabled(!isEnabled)
    }
}

/// The press look of an action row: the row lightens under the finger.
struct SettingsRowPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Theme.chromeRaised : Color.clear)
            .pressHaptic(configuration.isPressed)
    }
}

/// The red, full-width button that ends a settings sheet (disconnect, close): white text and icon on the destructive colour.
struct DestructiveWideButton: View {
    let title: LocalizedStringKey
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.body.weight(.semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 52)
        }
        .buttonStyle(DestructiveWideStyle())
    }
}

private struct DestructiveWideStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Theme.destructiveFill.opacity(0.8) : Theme.destructiveFill,
                        in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            .pressHaptic(configuration.isPressed)
    }
}
