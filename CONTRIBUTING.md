# Contributing

Thanks for helping. Bug reports, protocol findings and pull requests are welcome.

## Setup

```bash
swift build && swift test      # packages, runs on macOS, no device or Mac server needed
cd App && xcodegen generate    # generates the (git-ignored) Xcode project
```

Put your Apple Developer team in `App/Signing.local.xcconfig` (git-ignored) to run on a real device, and use your own bundle
identifier in `App/project.yml`. See the [README](README.md).

## Before you send a pull request

- `swift test` passes. Add a test with your change; most logic lives in testable packages (`RFBKit`, `InputKit`,
  `SessionKit`, `ConnectionKit`) with no UIKit.
- UI changes: build the app (`xcodebuild ... -destination 'generic/platform=iOS Simulator'`) and, where you can, run the
  UI tests against `Tools/mock-rfb-server` (it listens only on `127.0.0.1`).
- Keep it dependency-free. New third-party dependencies need a strong reason.
- Never commit secrets, captures or personal data: no passwords, team IDs, hostnames, `rfbprobe --record` output, `*.bgra`,
  `session*.bin` or screenshots of a real screen. The `.gitignore` covers the common cases; check your diff anyway.
- Security-sensitive code (authentication, key exchange, decoders that read server-controlled lengths) needs a test for the
  malicious case: bound every server-supplied length before allocating.

## Protocol findings

`docs/protocol-notes.md` records how Apple's Screen Sharing behaves, tagged **[QS]** observed, **[SL]** inferred, **[CB]** unknown.
Add what you can reproduce, with the macOS version. Do not paste Apple code, binaries or disassembly.

## Language

Everything in the repository is English: code, comments, docs, commit messages and UI strings. The app is translated into
Vietnamese through `vi.lproj/Localizable.strings` tables (English sentence = key). When you add or change a user-visible
string, add or update its Vietnamese entry too; other translations are welcome as new `<code>.lproj` folders. See
[`.claude/rules/localization.md`](.claude/rules/localization.md).

## License

By contributing you agree that your contribution is licensed under the [MIT License](LICENSE).
