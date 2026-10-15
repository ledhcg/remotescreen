# Localization and language

**English is the source language of everything in this repository.** Vietnamese exists only as a translation.

- **User-visible text** (labels, buttons, alerts, errors, notices, accessibility text, permission prompts): write the English
  sentence in code, translate it to Vietnamese in a `vi.lproj` table. Never hard-code Vietnamese in Swift.
  - Packages (`SessionKit`, `ConnectionKit`, `InputKit`, `RemoteDisplay`): call `tr("English text %@", arg)` (defined in each
    package's `Localized.swift`); translations live in `Sources/<Package>/Resources/vi.lproj/Localizable.strings` with the
    English sentence as the key, e.g. `"Wrong username or password." = "Sai tên tài khoản hoặc mật khẩu.";`.
    Use `%@` for strings, `%lld` for `Int`, and `%1$@ %2$lld` when the translation reorders arguments.
  - App (`App/ScreonApp`): SwiftUI `Text("English")` / `Button("English")` / `Label` use the sentence as the key;
    other `String`s use `String(localized: "English")`. Translations live in `App/ScreonApp/Resources/vi.lproj/Localizable.strings`;
    the iOS permission prompt is translated in `vi.lproj/InfoPlist.strings`.
  - `RFBKit` and `RFBCrypto` errors are developer-facing: English only, not localized. User-facing wording for them lives in
    `SessionKit/ConnectionFailureMessage`.
- **Tests** that assert on message text set `Localization.forcedLanguage = "en"` in the suite's `init()` so results do not depend
  on the machine's language. UI tests launch the app with `-AppleLanguages (en)`.
- **Code comments, docs, scripts, commit messages, issues**: English. Vietnamese appears only in `vi.lproj` tables, `README.vi.md`,
  and Unicode *test data* (for example passwords with diacritics).
- Keep Vietnamese complete and correct, with every diacritic. Add a translation whenever you add or change an English string;
  a missing key falls back to English, never to a blank.
- Do not rename an English key without updating its Vietnamese entry.
