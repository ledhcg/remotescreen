# RemoteScreen

**Control your Mac from an iPhone or iPad.** A native, dependency-free Swift client for Apple Screen Sharing
(RFB / VNC, including Apple's type 30 login), built around touch, Apple Pencil, mouse and trackpad.

[![CI](https://github.com/ledhcg/remotescreen/actions/workflows/ci.yml/badge.svg)](https://github.com/ledhcg/remotescreen/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
![iOS 18+](https://img.shields.io/badge/iOS-18%2B-lightgrey)
![Swift 6](https://img.shields.io/badge/Swift-6-orange)

[English](README.md) · [Tiếng Việt](README.vi.md)

> **Status: early (0.1.0).** It works against a real Mac (macOS 27) and on real iPad hardware, but the app name and
> bundle identifier are still provisional and several features are unverified. See
> [docs/app-status.md](docs/app-status.md) (Vietnamese) for what has and has not been tested.

## Features

- **Native RFB client, no third-party dependencies.** Handshake, security types None / VNC / Apple Remote Desktop
  (type 30), Raw, CopyRect and ZRLE decoding, cursor, clipboard. Big-number crypto is implemented in the package.
- **Metal rendering** with letterboxing, zoom/pan, actual-size mode and a remote cursor drawn in the right place.
- **Touch that behaves like a pointer.** Tap, double tap, two-finger tap (right click), press-and-hold to drag,
  momentum scrolling, Apple Pencil, and the iPad mouse/trackpad as an indirect pointer.
- **Hardware and on-screen keyboard** with modifier keys that stick, mapped to X11 keysyms.
- **Bonjour discovery** of Macs on your network and saved connections. Passwords are stored in the iOS Keychain
  (`WhenUnlockedThisDeviceOnly`), never in the connection list.
- **Stream quality modes**, automatic reconnect, and a clipboard bridge.

## Security notes — please read

- Only Apple's type 30 login protects your credentials. **The screen, keystrokes and clipboard travel
  unencrypted over RFB.** Use it on a network you trust, or tunnel it (for example over SSH or a VPN).
- VNC authentication (type 2) uses DES and is weak by design. Prefer an account login (type 30).
- Logging in with a username while the server only offers VNC authentication is refused rather than silently
  downgraded. Leave the username empty if you really want VNC-password login. Weak logins show a warning during the
  session.
- Apple's key exchange (type 30) does not authenticate the server, so a man in the middle can still impersonate it.
  The client rejects weak or non-prime Diffie-Hellman groups (below 2048 bits, composite, or oddly structured), but
  this does not replace a trusted network.
- Clipboard: with standard VNC servers, text the server pushes is **not** written to the iOS pasteboard on its own; it
  is copied only right after you copy on the Mac or press the button. Sync with macOS uses Apple's request/response
  protocol. Review the clipboard setting before connecting to a machine you do not control.
- The big-number arithmetic is not constant-time. It protects a fresh, per-connection key in an interactive session,
  but do not reuse it where local timing attacks matter.

To report a vulnerability, please do not open a public issue; see [SECURITY.md](SECURITY.md),
or contact the maintainer privately.

## Build

Requires Xcode 26+ (Swift 6), macOS to build, iOS 18+ to run.

```bash
swift build && swift test            # the packages (macOS), 55 tests, no device needed
```

The iPhone/iPad app uses [XcodeGen](https://github.com/yonaskolb/XcodeGen); the `.xcodeproj` is generated and not
committed.

```bash
cd App && xcodegen generate
open RemoteScreenApp.xcodeproj
```

To run on a real device you need an Apple Developer team. Put it in `App/Signing.local.xcconfig` (git-ignored):

```
DEVELOPMENT_TEAM = <YOUR_TEAM_ID>
CODE_SIGN_STYLE = Automatic
```

Change `bundleIdPrefix` / `PRODUCT_BUNDLE_IDENTIFIER` in `App/project.yml` to your own, since a bundle identifier can
belong to only one team.

## Layout

```
Sources/
  RFBCrypto/      DES, AES-ECB, MD5, 4096-bit big numbers (Montgomery), random numbers
  RFBKit/         RFB protocol: handshake, authentication, encodings, session
  RemoteDisplay/  viewport geometry, Metal renderer, UIKit view
  InputKit/       keyboard / touch / pencil mapping (pure logic)
  SessionKit/     reconnect policy, clipboard bridge, stream quality
  ConnectionKit/  saved computers, Bonjour browser, validation
App/              SwiftUI iPhone/iPad app, UI tests
Tools/            rfbprobe (diagnostics), mock-rfb-server and replay-check (test helpers)
docs/             protocol notes and app status
```

`Package.swift` uses `unsafeFlags` to optimise the hot paths in debug builds. SwiftPM only accepts that for local
packages, so these libraries can be used by path but not as a versioned remote dependency.

## Tools

- `swift run rfbprobe <host>`: protocol diagnostics against a real server. Credentials come from `RFB_USER` /
  `RFB_PASSWORD`. `--record` writes raw captures that contain screen content: never commit them.
- `Tools/mock-rfb-server`: a fake RFB server on `127.0.0.1` used by the end-to-end input tests.

## Contributing

Bug reports and pull requests are welcome. Run `swift test` before sending a change. Documentation and code
comments are currently written in Vietnamese; English contributions are welcome too.

## Trademarks

Apple, Mac, macOS, iPad, iPhone, Screen Sharing and Apple Remote Desktop are trademarks of Apple Inc. VNC is a
trademark of RealVNC Ltd. RemoteScreen is an independent project and is not affiliated with, endorsed by or sponsored
by Apple or RealVNC.

## License

[MIT](LICENSE)
