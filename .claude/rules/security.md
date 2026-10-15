---
paths:
  - "Sources/RFBKit/**/*.swift"
  - "Sources/RFBCrypto/**/*.swift"
  - "Sources/SessionKit/**/*.swift"
  - "App/RemoteScreenApp/**/*.swift"
---

# Security rules

The server is untrusted: it may be hostile, compromised or a man in the middle on the local network.

- **Bound before you allocate.** Rectangle sizes, `ServerInit` width/height, ZRLE palette/run lengths, zlib output, clipboard
  sizes and key lengths all come from the server. Use the existing caps (`Framebuffer.maxPixelCount`/`maxDimension`,
  `RFBSession.maxRawBandBytes`, `maxCutTextLength`, clipboard 16 MiB, `Authenticator.maximumKeyLength`) or add one. Read large
  payloads in bands, never in one `read(exactly:)`.
- **Authentication.** `RFBConnection.chooseSecurityType` accepts only type 30 when a username is present. Do not add fallbacks.
  Diffie-Hellman parameters pass `Authenticator.isAcceptableGroup` (≥ 2048 bits, prime, sane structure) before any key is made.
  Randomness comes from `SecureRandom` (`SecRandomCopyBytes`), never `random()` or `Int.random`.
- **Credentials.** Keychain only, `WhenUnlockedThisDeviceOnly`. Never in `connections.json`, logs, `print`, error strings or
  URLs. `vnc://user:pass@host` must not carry the password.
- **Clipboard.** Text a standard server pushes is not written to the pasteboard on its own (`ClipboardBridge.receive(cutText:)`).
  Sensitive types (`org.nspasteboard.*`) go through `writeSensitive` (local only, expiring).
- **No force-unwrap, `try!` or unchecked pointer arithmetic on server data.** Decoders throw `RFBError.malformed`.
- **Honest limits.** Apple type 30 does not authenticate the server and RFB is unencrypted; the UI warns, the README says so.
  The BigUInt arithmetic is not constant-time; do not use it for long-lived secrets.
- A security fix ships with a test for the malicious case, and a line in `CHANGELOG.md`.
