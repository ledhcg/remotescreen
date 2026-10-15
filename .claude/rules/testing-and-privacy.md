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
