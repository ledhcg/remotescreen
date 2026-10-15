---
name: release
description: Prepare a RemoteScreen release. Use only when the maintainer explicitly asks for a release.
---

# Release

1. Run the `verify` skill; all green. Confirm `gitleaks git --redact` is clean over the full history.
2. Update `CHANGELOG.md` (move Unreleased to the version), `MARKETING_VERSION`/`CURRENT_PROJECT_VERSION` in `App/project.yml`,
   and the status line in `docs/app-status.md`.
3. Distribution (ask first; needs the maintainer's Apple Developer account): archive with Xcode, sign with the
   maintainer's team (kept in `App/Signing.local.xcconfig`, never committed), upload to TestFlight/App Store.
4. Tag `vX.Y.Z` and create the GitHub release **only on request**. Never push tags or publish unless asked.
