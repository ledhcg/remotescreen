# Screon — agent guide

Native iPhone/iPad client for Apple Screen Sharing (RFB/VNC, ARD type 30): control a Mac with touch, Apple Pencil, mouse and
trackpad. Swift 6 / SwiftPM + an XcodeGen iOS app. iOS 18+. Open source (MIT). **No third-party dependencies.**
Read this first; detailed rules live in `.claude/rules/` and repeatable procedures in `.claude/skills/`.

## Layout

```
Sources/Localization   string lookup by language: the English sentence is the key; per-package `tr()` + `vi.lproj` tables
Sources/RFBCrypto      DES, AES-ECB, MD5, 4096-bit BigUInt (Montgomery), Miller-Rabin, SecureRandom. No UI
Sources/RFBKit         RFB protocol: handshake, auth, Raw/CopyRect/ZRLE, cursor, session, send queue. No UIKit
Sources/RemoteDisplay  viewport geometry, Metal renderer, ScreonView (UIKit)
Sources/InputKit       keyboard/touch/pencil → RFB events. Pure logic, no UIKit
Sources/SessionKit     reconnect policy, clipboard bridge, stream quality, user-facing messages. Pure logic
Sources/ConnectionKit  saved computers (JSON), Bonjour browser, form validation
Sources/LinkProtocol   App Mode wire format: frames, messages, bounded codecs. Pure, no I/O
Sources/LinkTransport  App Mode link: QUIC + TCP/TLS fallback, pinned identities, pairing, session machine
Sources/WindowKit      iPad-side window model, stream/input glue for App Mode
Sources/HelperCore     Mac-side helper logic (macOS only): capture, window control, authorization, files
Sources/CZlib          system zlib module map
Tools/rfbprobe         diagnostic CLI against a real server        Tools/mock-rfb-server  fake server for E2E tests (127.0.0.1)
Tools/replay-check     independent Python ZRLE encoder/decoder     Tools/mock-link-helper  fake Screon Helper for App Mode (127.0.0.1)
Helper/                macOS menu-bar helper app (project.yml = source of truth; ScreonHelper.xcodeproj is generated)
scripts/               helper release skeletons (make-helper-dmg.sh, sign-update-manifest.swift)
App/                   SwiftUI app (project.yml = source of truth; the .xcodeproj is generated and git-ignored)
docs/                  protocol-notes.md (what Apple's server does), app-status.md (what is verified)
```
Dependency direction: `App` → `SessionKit`/`RemoteDisplay`/`ConnectionKit` → `InputKit` → `RFBKit` → `RFBCrypto`.
App Mode: `App` → `WindowKit` → `LinkTransport` → `LinkProtocol`; `Helper` → `HelperCore` → `LinkTransport` → `LinkProtocol`
(`HelperCore` is macOS-only). Never import upward.

## Commands

```bash
swift build && swift test                                   # all packages, macOS, no device or Mac server needed
cd App && xcodegen generate                                 # generates ScreonApp.xcodeproj
xcodebuild -project App/ScreonApp.xcodeproj -scheme ScreonApp \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
Tools/mock-rfb-server/run_input_test.sh <simulator-UDID>    # E2E input against the fake server (never a real Mac)
RFB_USER=… RFB_PASSWORD=… swift run rfbprobe <host> --login 30   # real server; credentials only via env
(cd Helper && xcodegen generate) && xcodebuild -project Helper/ScreonHelper.xcodeproj -scheme ScreonHelper \
  -destination 'generic/platform=macOS' CODE_SIGNING_ALLOWED=NO build   # helper (needs Helper/project.yml)
swift run mock-link-helper                                  # fake helper on 127.0.0.1 for App Mode E2E (--self-test when supported)
```

## Non-negotiables

1. **Server data is hostile.** Every length, count, size or index read from the server is bounded before it allocates or
   indexes. New decoders need a malicious-input test. See `.claude/rules/security.md`.
2. **Never silently downgrade authentication.** With a username, only type 30 is accepted. Weak logins (VNC, None) must be
   warned about. Passwords live only in the Keychain: never in JSON, logs, URLs or test fixtures.
3. **No real data in the repo.** No captures (`rfbprobe --record`, `*.bgra`, `session*.bin`, `*.jsonl`), screenshots of a real
   screen, hostnames, usernames, team IDs, or Apple binary addresses/hashes. See `.claude/rules/testing-and-privacy.md`.
4. **Tests never touch a real Mac** unless the maintainer asks. Use the mock server and the simulator.
5. **No third-party dependencies.** `unsafeFlags` in `Package.swift` make the libraries local-only: do not add more.
6. **Do not decompile or paste Apple code** into the repo. Protocol findings are behavioural observations only
   (see the `protocol-finding` skill).
7. **App Mode link is hostile in both directions.** Pinned identities only, no unauthenticated link mode, pairing only
   while a Mac-side window is open and approved locally. See `.claude/rules/security.md`.
8. Do not rewrite git history, force-push, make the repo public/private or cut a release unless explicitly asked.

## Conventions

- Match surrounding code. **English is the source language of everything**: code, comments, docs, UI strings, commit messages.
  Vietnamese exists only as a translation (`vi.lproj` tables, `README.vi.md`) and as Unicode test data. See
  `.claude/rules/localization.md`. Reply to people in the language they write in.
- Logic goes in the pure packages with Swift Testing (`@Suite`/`@Test`/`#expect`); UIKit/SwiftUI stays thin.
- Hot paths (decode, upload, cursor) do not allocate per frame without a reason. They are built with `-O` even in debug.
- Any new user-visible string: English in code through `tr("…")` (or SwiftUI `Text("…")`), plus its Vietnamese entry in the
  matching `vi.lproj/Localizable.strings`. A test fails if a key has no Vietnamese entry (`LocalizationTests`).
- Update `CHANGELOG.md` (Unreleased) for user-visible changes and `docs/app-status.md` for what is now verified.
- Commits: Conventional Commits (`type(scope): summary`), body explains why, one logical change each. See `.claude/rules/git.md`.

## Skills (use via the Skill tool)

| Skill | When |
|---|---|
| `verify` | After any code change: build, test, iOS build, secrets scan, no stray Vietnamese |
| `security-review` | Touching auth, key exchange, decoders, clipboard, Keychain or anything reading server lengths |
| `protocol-finding` | Recording a new observation about Apple's server in `docs/protocol-notes.md` |
| `release` | Only when the maintainer asks for a release |

## Gotchas

- Debug builds of crypto/decoders are forced to `-O`; unoptimised 4096-bit math is ~25× slower and ZRLE ~60× slower.
- Apple's server ignores a client connecting to its own Mac (`You cannot control your own screen.`): use a second device or
  the mock server.
- iOS holds the connection in `.waiting` while the Local Network permission prompt is open; do not treat it as fatal.
- `RFB_HOST/USER/PASSWORD` auto-connect exists in DEBUG builds only.
- App Mode needs iPadOS/iOS 26 (RFB mode keeps iOS 18). The helper needs Accessibility and Screen Recording on the Mac
  (on macOS 27 the latter sits under the Remote Desktop category); tests must never depend on those grants (use fakes).
