---
name: release
description: Prepare a Screon release. Use only when the maintainer explicitly asks for a release.
---

# Release

1. Run the `verify` skill; all green. Confirm `gitleaks git --redact` is clean over the full history.
2. Update `CHANGELOG.md` (move Unreleased to the version), `MARKETING_VERSION`/`CURRENT_PROJECT_VERSION` in `App/project.yml`,
   and the status line in `docs/app-status.md`.
3. Distribution (ask first; needs the maintainer's Apple Developer account): archive with Xcode, sign with the
   maintainer's team (kept in `App/Signing.local.xcconfig`, never committed), upload to TestFlight/App Store.
4. Tag `vX.Y.Z` and create the GitHub release **only on request**. Never push tags or publish unless asked.

## Helper branch (Screon Helper for the Mac, only when the maintainer asks)

1. Run `verify` including the helper build; bump the helper version in `Helper/project.yml`; add its CHANGELOG line.
2. Run the manual workflow `.github/workflows/helper-release.yml` (or the same steps locally with the maintainer's Developer ID):
   archive, sign with Developer ID, `xcrun notarytool submit --wait`, `xcrun stapler staple`, then `scripts/make-helper-dmg.sh`
   to build and staple the `.dmg`.
3. Sign the update manifest with the Ed25519 key (`scripts/sign-update-manifest.swift`); the private key is a CI secret or lives
   on the maintainer's machine, never in the repo. The helper embeds only the public key.
4. Verify the `.dmg` on a clean Mac: `spctl -a -vvv`, `stapler validate`. Publish to a GitHub Release only on request.
   Never print, commit or log signing material.
