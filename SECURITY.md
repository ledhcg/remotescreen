# Security policy

## Supported versions

Only the latest release (and `main`) receives security fixes. The project is pre-1.0.

## Reporting a vulnerability

Please **do not open a public issue** for security problems.

- Use GitHub's private reporting: **Security → Report a vulnerability** on this repository, or
- email **mail@ledinhcuong.com** with a description, reproduction steps and the affected version.

You can expect an acknowledgement within a few days. Please allow reasonable time for a fix before public disclosure.

## Scope

In scope: authentication and key-exchange handling (downgrade, weak Diffie-Hellman parameters), memory or CPU
exhaustion and crashes caused by data from a malicious server (RFB rectangles, ZRLE, zlib clipboard payloads), leaking or
mis-storing credentials (Keychain, logs, saved connections), and clipboard handling.

App Mode (beta) adds: the link protocol and its decoders (either direction), pairing and device pinning (bypassing the
Mac-side approval, replayed or brute-forced pairing offers, identity confusion), the Screon Helper's capability surface
(anything that lets a paired or unpaired peer run commands, reach unauthorized windows or paths, or inject input outside the
session's windows), file transfer and "open on the Mac" handling, the shared clipboard, revocation not closing live sessions,
and the helper's update and release signing (manifest verification, notarization).

Known and documented limits, not vulnerabilities by themselves:

- RFB does not encrypt the screen, keystrokes or clipboard. Use a trusted network or a tunnel (VPN, SSH).
- Apple's type 30 key exchange does not authenticate the server.
- VNC authentication (type 2) uses DES and is weak by design.
- The big-number arithmetic in `RFBCrypto` is not constant-time.

Out of scope: vulnerabilities in macOS Screen Sharing or iOS itself (report those to Apple).

Please never attach real captures (`rfbprobe --record`, `*.bgra`, `session*.bin`) to a report: they contain screen content.
