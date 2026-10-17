# Changelog

## Unreleased

- Design system: one look for the whole app (`DesignSystem.swift`, rules in `.claude/rules/design-system.md`). Everything that floats
  over a remote screen is now dark and opaque with a hairline edge (no more grey frosted glass that washed out over a bright Mac
  screen), every icon is monochrome (blue only marks what is selected), all keys share one shape (modifiers, esc, tab, arrows,
  clipboard, sidebar), round buttons are one 44 pt style, corners are continuous with radii from one table, and the Windows
  sheet on iPhone is an opaque surface lighter than the black behind it instead of melting into it.
- The Mac picture has rounded corners (12 pt for the whole screen, the window's own radius in App Mode), which also hides the white
  or black wedges the Mac leaves in a window's corners.
- Deleting a computer from the list asks first and says what goes and what stays on the Mac (the pairing is still listed there).
  A full swipe no longer deletes.
- Each computer in the list has quick actions at the end of its row: Screen Sharing and App Mode. A computer whose App Mode is not
  set up shows a "set up" icon and opens the setup.
- Availability: the list now probes the Screen Sharing port of every saved computer (its own address and the ones its helper
  offered) and marks the ones that answer, instead of only trusting Bonjour, so computers reached over Tailscale show as available.
- Tailscale: computers on a tailnet get a black tile instead of the blue one, and the list says "Tailscale" (or that Tailscale is not
  connected). The network a computer was found on is saved with it. With an API token saved under Network (Keychain only, sent only to
  api.tailscale.com), the Macs of your tailnet that answer on Screen Sharing are listed under "On Tailscale" even before you save them.
- Fix: a hang in the App Mode TCP fallback (a lock held while a waiting task was resumed could deadlock with cancelling that task),
  found by sampling a test run that never ended; and the approval-race tests no longer depend on the order of two unrelated events.

- Fix: waits in the App Mode link (one-shot results, stream inboxes, the TCP fallback's stream reads) now end when their task
  is cancelled. Before, a cancelled task could wait forever, so shutting a session down did not stop it and a test run could
  hang for hours; replaced window and audio readers now drain their stream instead of being cancelled.
- Fix (Screon Helper 0.3.0 build 5): build 4 quit as soon as an iPhone or iPad opened a window (the capture background colour
  was freed while the stream copied its configuration), and could quit at launch or after a change in its window when several
  apps were tracked at once (the observer thread was started twice). Both are fixed, with regression tests.

- The helper release workflow now signs, notarizes and staples the disk image too, keeps the image and the signed update
  manifest as a run artifact, and publishes the GitHub Release only when `publish` is checked.
- Screon Helper 0.3.0 (build 4): fills a window's transparent rounded corners with black (no more dark wedges on the iPad),
  re-sends a key frame when its stream config could not go out, and finishes a window's old stream before opening the new
  one when the iPad re-subscribes.

## 0.3.0 — 2026-10-16 (TestFlight beta, build 6)

- The App Mode fixes on the Mac side (black window corners, a key frame re-sent when its stream config could not go out, a
  re-subscribed window stream replaced in order) need Screon Helper newer than 0.2.0 build 3; the iPad-side fixes work with
  build 3 already.

- Network: Screon now follows the device's network. Offline, it says so at once instead of timing out, and a dropped session
  waits for the network without using up its reconnect attempts. A session is reconnected right away when the device switches
  between Wi-Fi and mobile data or comes back after an outage of 3 s or more (shorter drops are left to the connection).
- Tailscale: Screon detects when Tailscale is connected on the device and shows it under Network (new button in the computer
  list), with a Use Tailscale switch. Tailscale addresses are skipped when they cannot answer, tried first on mobile data, and a
  Tailscale address typed for Screen Sharing explains what to do when Tailscale is off. An App Mode window that can only reach
  its Mac through Tailscale reconnects by itself once Tailscale connects.
- Cursor styles replace only the Mac's arrow: the text I-beam, resize arrows, the pointing hand and the crosshair stay the
  Mac's own, so you still see what a click will do.
- App Mode launcher: a failure that needs you (pair again, Tailscale) no longer shows a spinner, and Try again appears only
  where it can help.

- Fix: the Mac screen was partly hidden by the device. The iOS status bar sat over the Mac menu bar, and the notch or Dynamic
  Island, the home indicator and the rounded display corners covered the Mac's corners and Dock. The status bar is now hidden
  during a session, Fit keeps the whole Mac screen clear of them, and in Fill or zoomed in the covered edges can be dragged into
  view.
- Fix (App Mode): Mac windows showed dark wedges at their rounded corners; the letterbox is now black like the corners.
- Fix (App Mode): resizing or re-subscribing a window could drop the whole link ("reconnecting" on every window). A QUIC
  window stream the Mac finished was taken for a read error, and a replacement stream that arrived first was rejected.
- Fix (App Mode): a window could stay frozen on its last picture when the key frame after a reconnect or resize was lost; the
  iPad now keeps asking (rate-limited) and the helper re-sends one when its stream config could not go out.
- Fix (App Mode): a dead link (Wi-Fi change, Mac asleep) was not noticed for a minute or more; it is now closed and reconnected
  when pings go unanswered for about 35 s, and probed at once when the app returns to the foreground.
- Fix: closing a Screen Sharing window left its session running in the background; a write error left the screen frozen while
  the toolbar still said "Controlling"; key releases sent just before disconnecting could be lost, leaving a modifier stuck on
  the Mac; returning to the app during a failing reconnect attempt no longer waits out the full backoff.
- On iPhone, the full-desktop view no longer has a Done button floating over the session toolbar: Disconnect closes it.
- Session controls stay dark in Light Mode, wrapping banners use rounded rectangles, floating cards share continuous 18-point
  corners, and the "Gestures on Mac" options are disabled with servers that do not support them.

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
