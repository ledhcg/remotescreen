---
paths:
  - "docs/**/*.md"
  - "**/*.md"
---

# Docs and language

- `README.md`, `SECURITY.md`, `CONTRIBUTING.md`, `CODE_OF_CONDUCT.md`, `.github/*` are English; `README.vi.md` is Vietnamese.
  Keep both READMEs in sync when behaviour or security notes change.
- `docs/` and source comments are Vietnamese with full diacritics. Do not mix languages inside a file or strip diacritics.
- `docs/protocol-notes.md` tags claims **[QS]** observed, **[SL]** inferred, **[CB]** unknown. Never promote a claim without
  evidence, and never include Apple code, disassembly, function addresses or binary hashes.
- `docs/app-status.md` lists only what was verified, with the evidence (test name or measurement). Unverified work goes under
  "Chưa kiểm chứng".
- Do not name other products as design sources. Trademarks (Apple, macOS, VNC) are acknowledged in the README.
