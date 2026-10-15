# Documentation index

- [`protocol-notes.md`](protocol-notes.md): what Apple's Screen Sharing server (`screensharingd`) does on the wire, based on behavioural
  observation and inference only (handshake, security types, DH/SRP, ZRLE, clipboard, Apple-specific messages). It contains no Apple
  code, disassembly, function addresses or binary hashes.
- [`app-status.md`](app-status.md): what the iPhone/iPad app has actually been verified to do, with the evidence (test name or
  measurement), plus how to run and measure it. Anything unproven is listed under "Not yet verified".

Evidence tags used in `protocol-notes.md`: **[QS]** observed directly, **[SL]** inferred, **[CB]** unknown / needs verification.
Never promote a claim to a stronger tag without evidence.

English is the source language of this repository; see [`.claude/rules/localization.md`](../.claude/rules/localization.md).
