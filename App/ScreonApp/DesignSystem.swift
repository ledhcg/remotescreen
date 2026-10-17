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

// MARK: - Controls

/// A round button of the chrome (40 pt of icon in a 44 pt circle): white icon on a dark disc, accent fill while selected.
/// Used for buttons and, through `ChromeRoundLabel`, for menus.
struct ChromeRoundButtonStyle: ButtonStyle {
    var isSelected = false
    var isDestructive = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 18, weight: .medium))
            .foregroundStyle(isDestructive ? Theme.destructive : Theme.onChrome)
            .frame(width: Theme.Size.round, height: Theme.Size.round)
            .background(fill(pressed: configuration.isPressed), in: Circle())
            .overlay(Circle().strokeBorder(Theme.hairline, lineWidth: 1))
            .contentShape(Circle())
            .environment(\.colorScheme, .dark)
    }

    private func fill(pressed: Bool) -> Color {
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

/// A key of the extra-keys bar and of the sidebar: one shape, one fill, white label, accent fill while it is held or on.
struct KeyCapStyle: ButtonStyle {
    var isSelected = false
    var isDestructive = false
    /// A key of the sidebar is exactly this wide, whatever its label (esc is no wider than ⌘). `nil`: the key grows with its label, as
    /// esc, tab and home do on the keys bar.
    var fixedWidth: CGFloat?

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(isDestructive ? Theme.destructive : Theme.onChrome)
            .padding(.horizontal, fixedWidth == nil ? 10 : 0)
            .frame(minWidth: fixedWidth ?? Theme.Size.key.width, minHeight: Theme.Size.key.height)
            .frame(width: fixedWidth)
            .background(fill(pressed: configuration.isPressed), in: RoundedRectangle(cornerRadius: Theme.Radius.key, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.key, style: .continuous))
            .environment(\.colorScheme, .dark)
    }

    private func fill(pressed: Bool) -> Color {
        if isSelected { return Theme.accent }
        return pressed ? Theme.chromeRaised.opacity(0.7) : Theme.chromeRaised
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
