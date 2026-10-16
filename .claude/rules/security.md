---
paths:
  - "Sources/RFBKit/**/*.swift"
  - "Sources/RFBCrypto/**/*.swift"
  - "Sources/SessionKit/**/*.swift"
  - "App/ScreonApp/**/*.swift"
  - "Sources/LinkProtocol/**/*.swift"
  - "Sources/LinkTransport/**/*.swift"
  - "Sources/HelperCore/**/*.swift"
  - "Sources/WindowKit/**/*.swift"
  - "Helper/**/*.swift"
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

## App Mode link, pairing and helper

The iPad–Mac link and the Screon Helper are a second trust boundary: **both directions are hostile input** (a rogue helper
can attack the iPad, a rogue or replayed client can attack the Mac).

- **Pinned identities only.** After pairing, each side accepts exactly the peer key it pinned (SPKI). No trust-on-every-connect,
  no system-CA fallback, no "skip verification" flag, not even in DEBUG.
- **No unauthenticated or unencrypted link mode.** There is no plaintext transport and no negotiation down to one.
  A failed handshake closes the connection; it never retries weaker.
- **Pairing only while a Mac-side pairing window is open and approved locally** (LocalAuthentication on the Mac). Pairing
  secrets are single use, bound to the handshake transcript, with a fresh nonce per offer and rate limits per source.
- **The helper's capability surface is an allow-list**: capture, window list/focus/move/resize, input injection, clipboard,
  allow-listed file open. No shell, no scripting (AppleScript/JXA), no arbitrary paths, no launching arbitrary executables.
- **Input only to the session's authorized windows.** Authorization is re-checked at injection time (window still exists,
  still authorized, session still live), not only when the window was added.
- **Received files are opened only as allow-listed documents** (type allow-list, sandboxed destination, size cap, quarantine
  attribute); never executed, never opened by path chosen by the peer.
- **Revoking a device closes its live sessions** immediately and removes the pin.
- **Bound every length, count and id on both sides** before allocating; decoders throw, never trap. Every new message needs a
  malicious-input test in `LinkProtocolTests` / `MaliciousPeerTests`.
- Keys and pairing material live in the Keychain only; never in logs, `UserDefaults`, JSON or test fixtures (tests generate
  identities per run). Link identity keys use `AfterFirstUnlockThisDeviceOnly` (a locked iPad or Mac must still reconnect);
  passwords keep `WhenUnlockedThisDeviceOnly`.
