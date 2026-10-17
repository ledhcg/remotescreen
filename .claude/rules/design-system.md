# Design system

The look of Screon lives in **one file**: `App/ScreonApp/DesignSystem.swift` (`Theme`, the button styles, the surfaces, the computer
tile). Draw nothing with a raw colour, a raw radius or a stock material; use what is there, and add to that file when something
is missing. A screen that looks different from its neighbours is a bug.

## Two layers

- **Chrome**: everything that floats over a remote screen (session toolbar, keys bar, sidebar, window buttons, tabs, banners,
  status cards, file-transfer card, bottom sheets of a session). It is **always dark** and **opaque enough to read over any
  picture**, whatever the device's appearance. Never `.ultraThinMaterial` or `.regularMaterial`: over a bright Mac screen they
  wash out to grey and the icons disappear.
- **Screens**: the computer list, settings, pairing, login. They follow the system appearance and use system colours
  (`.primary`, `.secondary`, `Color(.secondarySystemFill)`, grouped lists).

## Colour

- One accent, `Theme.accent`, set as the app's `.tint`. It marks **selection** (a key that is held, the keyboard button while the
  keyboard is up, the current tab, the current window in a list), the **primary action** (a prominent button) and **text
  buttons** (Done, Save, Connect).
- **Icons are never accent-coloured at rest.** In chrome they are white (`Theme.onChrome`); on screens they are `.primary`
  (icon-only toolbar buttons get `.tint(.primary)`). A blue icon on a grey disc is the old look: do not bring it back.
- Destructive is `Theme.destructive` in chrome, `role: .destructive` on screens. Available/online is `Theme.online` (a dot).
- Computer tiles: **blue** for the local network, **black** (with a faint edge) for Tailscale. Any new network source gets its own
  tile in `Theme.tile(for:)`, and `NetworkSource` in ConnectionKit carries it.

## Shape

- Every corner is **continuous** (`style: .continuous`, `layer.cornerCurve = .continuous`). A plain `cornerRadius` is a bug.
- Radii come from `Theme.Radius`: card 18, control 12, key 10, sheet 28, tile and app icons `side * 0.24`. Nothing else.
- A pill (`Capsule`) holds one line of controls. Text that can wrap (any banner, any message) goes in a rounded rectangle
  (`chromeBanner()`), never a capsule: its round ends cut into the second line.
- Every chrome surface has the 1 pt `Theme.hairline` edge, so it is visible on black and on a bright picture alike.
- The Mac picture itself is drawn with rounded corners by the renderer (12 pt for the full screen; 14 Mac points, scaled, for
  an App Mode window), because the Mac fills the corners of a window inconsistently (white in some, black in others).

## Controls

- Round chrome button: `ChromeRoundButtonStyle` (44 pt disc, white icon, accent fill while selected). For a `Menu`, whose label
  cannot take a button style, use `ChromeRoundLabel`. Do not hand-draw a disc.
- Key (extra-keys bar, sidebar): `KeyCapStyle`, **one size (44 × 40)**, one fill, white label, accent fill while held or on. Modifier
  keys, esc, tab, arrows, home/end, clipboard keys and the sidebar buttons are all the same cap: a word (esc, home) is set smaller with
  `KeyCapText`, a menu key is drawn with `KeyCapLabel`; no key is wider or narrower than another. The system Paste button draws its own
  icon, so it is scaled and clipped to the cap.
- **Destructive** (disconnect, close): a **red fill with a white icon and text** (`Theme.destructiveFill`), never a red icon on grey. In
  the toolbar it is `ChromeRoundButtonStyle(isDestructive: true)`; at the foot of a sheet it is `DestructiveWideButton`, full width.
- Quick action on a list row: `QuickActionStyle`.
- **Hit target is 44 pt minimum**, even where the visible disc is 40: pad the hit area, never shrink it.
- Surfaces: `chromePill()`, `chromeBanner()`, `chromeCard()`, `chromeSheet()` (+ `chromeList()` for a list inside it). A bottom
  sheet over a session is **opaque and lighter than the black behind it** (`Theme.sheet`), with a visible grabber, so its edge can
  be seen. UIKit views use the same values through `UIColor(Theme.…)`.
- A control that is not available is dimmed (opacity 0.4) and says why when the reason is not obvious.

## Settings

Settings of a session (the "…" button, Screen Sharing and App Mode alike) are a **bottom sheet**, not a system menu: `SettingsSheet`
with `SettingsGroup` cards. A row has the **icon and title on the left and the current value on the right**; tapping the value opens a
menu of the other values (`SettingsMenuRow`). An on/off setting is a switch (`SettingsToggleRow`), something that does a thing is a
`SettingsActionRow`. The last thing in the sheet is the full-width red `DestructiveWideButton` (Disconnect, or Close this window).
The Mac app's menus open in their own sheet (`RemoteMenuSheet`), which asks the Mac when it opens.

## Haptics

**Every touch point answers with a haptic.** The button styles (`ChromeRoundButtonStyle`, `KeyCapStyle`, `QuickActionStyle`, the
settings row styles) add a light tap when the finger goes down (`pressHaptic`), a picker, toggle or segment ticks when its value
changes (`selectionHaptic`), and a control that handles touches itself (a `UIControl` such as the sidebar's modifier keys) calls
`Haptics.tap()`. Use `Haptics.success()` when something finishes well and `Haptics.warning()` before a destructive action runs. A new
button style without `pressHaptic` fails `DesignRulesTests`. Do not add a haptic to the Mac picture itself: its touches are the
Mac's input, not controls.

## Lists of computers

- Tile, name, then where it is (`account@host`, plus `· Tailscale` for a tailnet computer, plus the reason when Tailscale is off).
- **Quick actions at the end of the row**, in this order: Screen Sharing (`display`), App Mode (`macwindow.on.rectangle`). When a
  saved computer has no App Mode yet the second button shows `macwindow.badge.plus` and opens the **setup**, not an error.
- Deleting a saved computer **always asks first** (alert: what goes, what stays on the Mac). A swipe never deletes on its own
  (`allowsFullSwipe: false`).
- Availability is a green dot on the tile, from Bonjour or a probe of the computer's addresses. Not seen is not "off".

## Checklist before a UI change is done

1. No `.ultraThinMaterial`, `.regularMaterial`, raw `Color.blue`, `cornerRadius` without `.continuous`, or hand-made round button.
2. Every icon is monochrome except where it is the selected one.
3. Every control answers with a haptic; hit targets ≥ 44 pt; labels for VoiceOver; every new string in English in code and Vietnamese in `vi.lproj`.
4. Looked at on an iPhone (390 pt wide) and an iPad, in light and dark appearance, and over a bright and a dark remote screen.
5. `docs/app-status.md` says what was looked at and what was not.
