# Changelog

## Unreleased

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
