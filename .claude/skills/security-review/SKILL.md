---
name: security-review
description: Review a change to Screon's authentication, key exchange, decoders, clipboard, Keychain, the App Mode link, pairing or helper, or any code that reads lengths from the server or a link peer. Use before committing such a change.
---

# Security review

Read `.claude/rules/security.md`, then for the diff check:

1. **Lengths:** every server-supplied number is bounded before allocation, indexing or multiplication (look for `width * height`,
   `count * size`, `read(exactly:)`, `Data(count:)`, `reserveCapacity`). Overflow is impossible or checked.
2. **Failure mode:** malformed input throws `RFBError`, never traps. No `!`, `try!`, `fatalError`, unchecked `UnsafePointer` math.
3. **Auth:** no new downgrade path; `chooseSecurityType` still returns only type 30 with a username; DH checks still run first.
4. **Secrets:** nothing sensitive reaches logs, `print`, errors, `UserDefaults`, JSON or URLs; Keychain class unchanged.
5. **Clipboard/pasteboard:** server pushes are still not written unprompted; sensitive types stay local and expiring.
6. **Tests:** a test feeds the malicious case (oversized length, truncated stream, bad group, hostile text) and expects an error.
7. Run the `verify` skill. Write findings as severity + file:line + scenario + fix; do not invent issues you did not read in code.

## Link, pairing and helper checklist (App Mode)

Also read the "App Mode link, pairing and helper" section of the rules. For changes under `Sources/Link*`, `Sources/HelperCore`,
`Sources/WindowKit`, `Helper/`:

1. **Pinning:** every connection validates the peer SPKI against the stored pin; no CA fallback, no skip flag, no plaintext path.
2. **Transcript binding:** pairing proofs and session tokens are bound to the handshake transcript (both identities, nonces).
3. **Nonce per offer:** each pairing offer has a fresh random nonce, single use, short expiry; replay is rejected (test).
4. **Rate limits per source:** failed pairing/handshake attempts are limited per source and cannot exhaust CPU or memory.
5. **Pairing window:** pairing is accepted only while the Mac-side window is open and approved locally.
6. **Revoke:** revoking a device removes its pin and closes its live sessions at once (test with a connected client).
7. **Authorization at injection time:** input, focus and move/resize re-check window and session authorization when executed.
8. **Capability allow-list:** no shell, scripting, arbitrary path or arbitrary app launch reachable from any message.
9. **Files:** received files are opened only as allow-listed document types in the sandboxed inbox, never executed.
10. **Bounded decoding both ways:** the iPad bounds what the helper sends and the helper bounds what the iPad sends; hostile
    peer tests exist for each new message (`LinkProtocolTests`, `MaliciousPeerTests`).
11. **Secrets and privacy:** keys only in the Keychain; no window titles, app names or captures in logs, fixtures or errors.
