---
name: security-review
description: Review a change to RemoteScreen's authentication, key exchange, decoders, clipboard, Keychain or any code that reads lengths from the server. Use before committing such a change.
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
