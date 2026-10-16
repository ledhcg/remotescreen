# Changelog

## Unreleased

- Screon Helper (macOS menu bar app for App Mode): shows who is connected, pairs iPads with a QR code or six digits (approved on the
  Mac with Touch ID or your password), lists, renames and revokes paired iPads, guides you through the macOS permissions, can open at
  login, and tells you when a newer helper is released (checked against a signed manifest; nothing is installed automatically).
- App Mode (iPadOS 26, beta, needs Screon Helper on the Mac): set up from a saved computer by scanning the pairing code, pasting its
  link or comparing six digits; each Mac window can open in its own iPad window with video, child menus and popovers, a local
  cursor, touch, Apple Pencil, mouse, trackpad and keyboard input, input methods such as Vietnamese Telex, and clear messages when
  the Mac is locked, a permission is missing, the device was removed or the apps need updating.
- App Mode: sound from the Mac apps (48 kHz 16-bit PCM through a 20 to 40 ms adaptive jitter buffer with drift correction; muted
  while the app's windows are in the background), clipboard sync on the link (text, RTF, HTML, PNG; password-manager content is
  never sent and sensitive content from the Mac stays on the iPad and expires; synced when a window comes forward and before
  paste), dropping files on a window to send them to the app that owns it (progress and cancel on screen; the Mac opens only plain
  documents), Apple Pencil pressure, tilt and hover for drawing apps, and per-computer streaming settings (quality cap, frame-rate
  cap, 10-bit video, sound).
- App Mode link protocol (unreleased, so changed in place): audio codecs `pcm16` and `aacEld` (Opus stays reserved), `status`
  `secureInput` now says when it ends, new `window.subscribeFailed` so the iPad can say why a window did not stream, and keys with
  keycode 0xFFFF are mapped from their keysym on the Mac.
- Helper (App Mode): ending one iPad's session no longer releases keys or buttons another iPad is holding; Pencil tilt is now
  converted to the range the system's tablet events expect.
- App Mode launcher and multi-window experience (iPadOS 26): a launcher scene with running apps (and their window counts), recent
  and all installed apps, search and cached icons; opening an app shows its windows as separate iPad windows or as tabs in one
  window (setting); an already open window comes forward instead of opening twice; iPad windows follow the Mac window (title,
  size limits) and resize it once you stop dragging; the Mac app's menus appear in the iPad menu bar and in a "Menus" button,
  Mac key equivalents work as shortcuts, and ⌘W either closes the iPad window or goes to the Mac (setting); window actions (close,
  minimise, zoom, exit full screen, show on full desktop); new Mac windows open by themselves or show a badge; windows are found
  again after a reconnect, a helper restart or a relaunch; on iPhone one window at a time with a window switcher.
- Helper (App Mode): input is injected only when the target window is verifiably the topmost window under the pointer (or the
  same app's own popup); otherwise the window is raised first. Unknown window numbers and foreign overlays fail closed.
- English is now the source language of the whole project (UI strings, code comments, docs, tools). Vietnamese is a translation
  in `vi.lproj` tables and `README.vi.md`. New `Localization` target; the iOS permission prompt is localized too.
- The app is now called **Screon** (Screen + On: a screen that stays connected), with a new app icon. Bundle identifier is `com.ledinhcuong.screon`.
- Project documentation and automation: `CLAUDE.md`, `AGENTS.md`, `.claude/` rules and skills, CI, issue and pull request templates,
  Dependabot, `CODEOWNERS`, `.editorconfig`.
- App Mode (beta, in progress): individual Mac windows as iPad windows through the Screon Helper menu-bar app, over a pinned,
  mutually authenticated link (pairing approved on the Mac, revocable). Needs iPadOS 26 and the helper; RFB mode is unchanged.
  New packages `LinkProtocol`, `LinkTransport`, `WindowKit`, `HelperCore`, tool `mock-link-helper`, and a manual
  helper release workflow (Developer ID, notarization).

## 0.1.0

First public release.

- Native RFB client: handshake, None / VNC / Apple Remote Desktop (type 30) authentication, Raw, CopyRect and ZRLE, cursor,
  clipboard (Apple's protocol and standard cut-text), Metal rendering.
- iPhone and iPad app: touch, Apple Pencil, mouse and trackpad, hardware and on-screen keyboard, Bonjour discovery,
  saved connections with Keychain-stored passwords, quality and display modes, automatic reconnect.
- Security: an account login never silently falls back to VNC authentication; Diffie-Hellman groups are validated
  (≥ 2048 bits, Miller-Rabin); Raw rectangles are read in bands and the framebuffer is capped at 8K; server-pushed standard
  clipboard text is not written to the pasteboard unprompted; the app warns about unencrypted transport and weak logins.
