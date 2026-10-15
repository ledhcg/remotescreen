---
name: verify
description: Verify a change to RemoteScreen — build, run all package tests, build the iOS app for the simulator, and scan for secrets. Use after any code change and before committing.
---

# Verify

1. `swift build` then `swift test`. All suites must pass; report counts, never "should pass".
2. If anything under `App/` changed, or a public API used by the app changed:
   `cd App && xcodegen generate && cd ..` then
   `xcodebuild -project App/RemoteScreenApp.xcodeproj -scheme RemoteScreenApp -destination 'generic/platform=iOS Simulator' -derivedDataPath <scratch dir> CODE_SIGNING_ALLOWED=NO build`
   (use a scratch derived-data path, not `App/build`).
3. UI or input changes: run the matching `Tools/mock-rfb-server/run_*_test.sh <simulator-UDID>` (fake server only).
4. `gitleaks dir . --redact` (or `gitleaks git --staged --redact` before a commit). `Tests/**/*Vectors.swift` are allow-listed.
5. No stray Vietnamese: grep outside `vi.lproj`, `README.vi.md` and deliberate Unicode test data for Vietnamese letters
   (`grep -rnP '[àáảãạăâèéẻẽẹêìíỉĩịòóỏõọôơùúủũụưỳýỷỹỵđ]' Sources App Tools docs --include='*.swift' --include='*.md' --include='*.py' --include='*.sh' --exclude-dir=vi.lproj`).
   Every new `tr("…")` key must have its `vi.lproj` entry (`LocalizationTests` checks SessionKit and ConnectionKit).
6. Check you left nothing behind: no `events.jsonl`, `*.bgra`, `session*.bin`, screenshots, `App/build*`.
7. Report what you ran and what you could **not** run (real Mac, real device).
