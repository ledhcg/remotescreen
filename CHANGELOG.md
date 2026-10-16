# Changelog

## Unreleased

- Cursor styles: the session menu has a Cursor submenu where you can keep the Mac's own pointer or pick one of six Screon
  arrows (filled or outlined, plain or with click rays, dots, a dashed or a dotted ring). The arrows are drawn as vectors
  at high resolution with a white halo, so they stay sharp and visible on dark and light content; App Mode windows use the
  same choice. When the Mac hides its pointer, the chosen arrow is hidden too.
- iPad pointer: with a mouse or trackpad, the round iPadOS pointer can be replaced by one of the same six arrows on the app's own
  screens (Pointer menu in the computer list's toolbar). Buttons keep their hover effect, and the Mac screen still shows the
  Mac's cursor.
- Fix: in the session's options menu the item icons were tinted white (the toolbar button's colour) while their text was
  dark, so the icons were almost invisible in Light Mode. Icons now follow the text colour.

- Screon Helper has the Screon app icon, and is distributed as a Developer ID-signed, notarized download (0.2.0, build 3).

- Fix (App Mode): on iPhone, a window opened and was immediately shown as "closed on the Mac". A tooltip of the Mac app (a
  tiny window Accessibility reports as a window) counted as a new window, and the iPhone switched its only screen to it just
  before it vanished. The helper no longer treats popup-sized or popup-layer windows as windows, and on iPhone new Mac
  windows only get a badge instead of replacing the window being used.

- Fix (Screon Helper): a window opened on the iPhone or iPad loaded and was then shown as "closed on the Mac" at once. Moving it
  onto the virtual display gave it a new Accessibility element, which the helper took for a new window. Windows are now
  identified by their window-server number, and the virtual display is off by default until it is proven on more Macs.

- Fix (Screon Helper): every Mac app showed "0 windows" and no window could be opened with the release build of the helper:
  an optimizer-only bug attached every window to pid 0. Windows now list and stream correctly.
- Fix (Screon Helper): opening a window that is minimised on the Mac showed "Waiting for the first frame" forever; the helper
  now restores it first, because a minimised window delivers no frames.

- App Mode over Tailscale (or another VPN): the helper's pairing code and window now include its Tailscale address (100.x)
  next to the LAN ones, and a paired iPhone or iPad remembers every address and tries them in turn when it reconnects, so App
  Mode keeps working away from the home network. Devices paired earlier need to pair again once to learn the extra address.

## 0.2.0 — 2026-10-16 (TestFlight beta)

- Screon Helper 0.2.0 (build 2), the same version as the iOS app.
- Fixes from testing App Mode on a real iPad and Mac: the helper starts on a real Mac (its identity lives in the login
  keychain), windows actually stream (capture uses the window-server number), the helper keeps a well-known port so a paired
  iPad reconnects after a restart, pairing waits while iOS asks for Local Network access, the launcher says when the helper
  lacks permissions, and the helper's pairing window offers Copy Link and shows the Mac's address and port.
- **App Mode (beta, iPadOS 26, needs the Screon Helper on the Mac):** individual Mac windows as iPad windows over a pinned,
  mutually authenticated link (QUIC, TCP+TLS fallback). Set up from a saved computer by scanning the pairing code, pasting its
  link or comparing six digits; pairing is approved on the Mac and can be revoked there. RFB mode is unchanged.
  - Windows: each Mac window in its own iPad window (or as tabs) with video, child menus and popovers, a local cursor, touch,
    Apple Pencil (pressure, tilt, hover), mouse, trackpad and keyboard input, and input methods such as Vietnamese Telex.
  - Launcher: running apps with window counts, recent and installed apps, search, cached icons; an open window comes forward
    instead of opening twice; iPad windows follow the Mac window and resize it once you stop dragging; windows are found again
    after a reconnect, a helper restart or a relaunch; on iPhone one window at a time with a switcher.
  - Menus and shortcuts: the Mac app's menus in the iPad menu bar and a "Menus" button, Mac key equivalents as shortcuts, ⌘W
    setting, window actions (close, minimise, zoom, exit full screen, show on full desktop), new windows open or show a badge.
  - Sound (48 kHz PCM, 20–40 ms adaptive jitter buffer), clipboard sync (text, RTF, HTML, PNG; password-manager content never
    sent), file drop onto a window (the Mac opens only plain documents), per-computer streaming settings.
  - Clear messages when the Mac is locked, a permission is missing, a window cannot stream, the device was removed or the apps
    need updating.
- **Screon Helper** (macOS menu bar app): shows who is connected, pairs iPads with a QR code or six digits (approved with Touch ID
  or the account password), renames and revokes paired iPads, guides through the macOS permissions, can open at login, and tells
  you when a newer helper is released (signed manifest; nothing is installed automatically).
- Security (App Mode):
  - Pairing secrets are single use, bound to the TLS transcript, scoped to the pairing method the Mac user opened, one pairing at
    a time, rate-limited per address; six-digit pairing is a human comparison, never derived on the wire.
  - A revoked or disconnected device can no longer act on messages it had queued; one host cannot hold every handshake slot;
    an extra iPad beyond the session limit is refused before it is welcomed (close code 9).
  - The helper injects input only into the session's own windows when they are verifiably topmost (unknown windows and other
    apps' overlays fail closed); keys go only to a window of the session; ending one iPad's session releases only its input.
  - Received files open only as allow-listed documents, with an app that declares it opens them, never with apps that run code,
    never macro-enabled Office or SVG files, and never without the quarantine mark.
  - Images and video from the helper are bounded before decoding; only PNG/JPEG are accepted for surfaces and cursors.
- New packages `LinkProtocol`, `LinkTransport`, `WindowKit`, `HelperCore`, the `mock-link-helper` test tool, and a manual
  helper release workflow (Developer ID, notarization, signed update manifest).
- Fix: a pairing offer and a resume token issued in the same instant are evicted oldest first; file names in transfers are
  validated on Unicode scalars (combining marks can no longer hide a leading dot).
- English is now the source language of the whole project (UI strings, code comments, docs, tools). Vietnamese is a translation
  in `vi.lproj` tables and `README.vi.md`. New `Localization` target; the iOS permission prompt is localized too.
- The app is now called **Screon** (Screen + On: a screen that stays connected), with a new app icon. Bundle identifier is `com.ledinhcuong.screon`.
- Project documentation and automation: `CLAUDE.md`, `AGENTS.md`, `.claude/` rules and skills, CI, issue and pull request templates,
  Dependabot, `CODEOWNERS`, `.editorconfig`.

## 0.1.0

First public release.

- Native RFB client: handshake, None / VNC / Apple Remote Desktop (type 30) authentication, Raw, CopyRect and ZRLE, cursor,
  clipboard (Apple's protocol and standard cut-text), Metal rendering.
- iPhone and iPad app: touch, Apple Pencil, mouse and trackpad, hardware and on-screen keyboard, Bonjour discovery,
  saved connections with Keychain-stored passwords, quality and display modes, automatic reconnect.
- Security: an account login never silently falls back to VNC authentication; Diffie-Hellman groups are validated
  (≥ 2048 bits, Miller-Rabin); Raw rectangles are read in bands and the framebuffer is capped at 8K; server-pushed standard
  clipboard text is not written to the pasteboard unprompted; the app warns about unencrypted transport and weak logins.
