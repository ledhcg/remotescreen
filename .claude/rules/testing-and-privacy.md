# Testing and privacy

- `swift test` must pass without a device, a Mac server or network access (Bonjour tests use a local listener).
- End-to-end input/UI tests run only against `Tools/mock-rfb-server` (binds `127.0.0.1`) and the simulator.
  Never point a test at a real Mac; `rfbprobe` against a real server only when the maintainer asks, with credentials in
  environment variables.
- Test data is synthetic: usernames like `alice`, hosts like `mac.local` or `10.0.0.2`, passwords like `s3cret`.
  Real server hellos may be kept only if they contain public parameters (see `RealServerFixture`).
- Never commit: `rfbprobe --record` output, `*.bgra`, `session*.bin`, `*.jsonl`, `.snapshots/`, simulator or device
  screenshots showing a real screen, `App/Signing.local.xcconfig`, team IDs, device UDIDs, real hostnames.
- Delete screenshots and logs you created for debugging. Before a commit run `gitleaks git --staged --redact`.
- Cryptographic and decoder code is tested against independent references (OpenSSL/hashlib/Python vectors, `Tools/replay-check`).
  Fuzz-style tests (`ZRLEFuzzTests`) must keep passing; extend them when you add an encoding.

## App Mode and the helper

- Helper tests never require Accessibility, Screen Recording or any other permission: capture, windows, input and files sit
  behind protocols with fakes. `swift test` must pass on a machine where nothing has been granted.
- End-to-end App Mode tests run only against `Tools/mock-link-helper` on `127.0.0.1` (and the simulator). Spikes on a real Mac
  or iPad (S1–S11 in `docs/app-mode-implementation-plan.md`) only when the maintainer asks.
- Never commit captures of real windows, window titles, app names from a real desktop, screenshots of the helper showing real
  content, or link transcripts. Test windows are synthetic (`Notes-fake`, `Doc 1`). Link test identities are generated per run.
