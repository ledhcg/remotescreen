---
name: protocol-finding
description: Record a new observation about Apple's Screen Sharing server in docs/protocol-notes.md with the right evidence tag. Use when you learn something new about message formats, encodings or authentication.
---

# Protocol finding

1. Reproduce it against the mock server or, if the maintainer allows, with `rfbprobe` on a real server (credentials from env).
2. Add it to the right section of `docs/protocol-notes.md` (Vietnamese, with diacritics), tagged:
   **[QS]** observed/measured (state macOS version and how), **[SL]** inferred (state the reasoning), **[CB]** unknown.
3. Cite evidence: a test name, an `rfbprobe` flag, or numbers. Raw captures are never committed; put at most the public,
   non-secret bytes into a test fixture.
4. Do **not** paste Apple code, disassembly, function addresses, binary hashes or proprietary strings beyond protocol field names.
5. Add or update a test that pins the behaviour, and update `docs/app-status.md` if it changes what is verified.
