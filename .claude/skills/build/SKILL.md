---
name: build
description: Build Screon (iOS app) and Screon Helper (Mac app) in Debug or Release. Release covers the TestFlight upload for the app and the signed, notarized .dmg plus install into /Applications for the helper. Use when asked to build, archive, upload to TestFlight, or install the helper.
---

# Build

Ask which target (**app**, **helper**, or both) and which kind (**debug** or **release**) if the request does not say.
Debug is free to run. **Release uploads or installs something: only when the maintainer asks** (see `.claude/rules/git.md`).
Scratch output goes to `$SCR` (the session scratchpad or a `mktemp -d`), never `App/build*`. Nothing below is committed:
identities, team and notary profile come from the environment or the git-ignored `*/Signing.local.xcconfig`.

```bash
SCR=${SCR:-$(mktemp -d)}
(cd App && xcodegen generate) ; (cd Helper && xcodegen generate)   # project.yml is the source of truth
```

## App: debug

```bash
# Simulator (no signing)
xcodebuild -project App/ScreonApp.xcodeproj -scheme ScreonApp -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath $SCR/dd-app CODE_SIGNING_ALLOWED=NO build
# Device: needs the maintainer's team in App/Signing.local.xcconfig
xcodebuild -project App/ScreonApp.xcodeproj -scheme ScreonApp -configuration Debug -destination 'generic/platform=iOS' \
  -derivedDataPath $SCR/dd-app -allowProvisioningUpdates build
```
Run it with the mock server: `Tools/mock-rfb-server/run_input_test.sh <simulator-UDID>` (never a real Mac).

## App: release (TestFlight)

1. Run the `verify` skill. Bump `CURRENT_PROJECT_VERSION` (and `MARKETING_VERSION` for a new version) in `App/project.yml`;
   App Store Connect rejects a build number it has already seen.
2. Archive, then export with upload:
```bash
V=<marketing>-<build>
xcodebuild archive -project App/ScreonApp.xcodeproj -scheme ScreonApp -configuration Release \
  -destination 'generic/platform=iOS' -archivePath $SCR/Screon-$V.xcarchive -derivedDataPath $SCR/dd-archive -allowProvisioningUpdates
cat > $SCR/ExportOptions.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>upload</string>
  <key>signingStyle</key><string>automatic</string>
  <key>uploadSymbols</key><true/>
  <key>manageAppVersionAndBuildNumber</key><false/>
</dict></plist>
PLIST
xcodebuild -exportArchive -archivePath $SCR/Screon-$V.xcarchive -exportOptionsPlist $SCR/ExportOptions.plist \
  -exportPath $SCR/export-$V -allowProvisioningUpdates
```
3. Success is `Upload succeeded` and `EXPORT SUCCEEDED`. Apple then processes the build for a few minutes. A new build shows
   "Missing Compliance" until the export-compliance question is answered in App Store Connect (maintainer's job).

## Helper: debug

```bash
xcodebuild -project Helper/ScreonHelper.xcodeproj -scheme ScreonHelper -configuration Debug \
  -destination 'generic/platform=macOS' -derivedDataPath $SCR/dd-helper CODE_SIGNING_ALLOWED=NO build
```
An unsigned build cannot hold Accessibility / Screen Recording grants, so it is for compiling and the fake-link tests only
(`swift run mock-link-helper`). To try the real helper, build Release below.

## Helper: release (signed, notarized, installed)

Needs a Developer ID Application identity and a `notarytool` keychain profile. Set `SIGN_IDENTITY` (the identity's full name,
from `security find-identity -v -p codesigning`), `NOTARY_PROFILE` (name given to `xcrun notarytool store-credentials`).

1. Run `verify` including the helper build. Bump `CURRENT_PROJECT_VERSION` (and `MARKETING_VERSION`) in `Helper/project.yml`.
   Rebuild the helper whenever `Sources/LinkTransport`, `LinkProtocol`, `HelperCore` or `Helper/` changed.
2. Archive with Developer ID and hardened runtime:
```bash
TEAM=$(security find-identity -v -p codesigning | grep "$SIGN_IDENTITY" | sed -E 's/.*\(([A-Z0-9]{10})\)"$/\1/')
V=<marketing>-<build>; R=$SCR/helper-release-$V
xcodebuild -project Helper/ScreonHelper.xcodeproj -scheme ScreonHelper -configuration Release -destination 'generic/platform=macOS' \
  -archivePath $SCR/ScreonHelper-$V.xcarchive -derivedDataPath $SCR/dd-helper-release CODE_SIGN_STYLE=Manual \
  "CODE_SIGN_IDENTITY=$SIGN_IDENTITY" DEVELOPMENT_TEAM=$TEAM "OTHER_CODE_SIGN_FLAGS=--timestamp" ENABLE_HARDENED_RUNTIME=YES archive
```
3. Notarize and staple the app, then build, sign, notarize and staple the disk image:
```bash
mkdir -p $R && ditto $SCR/ScreonHelper-$V.xcarchive/Products/Applications/ScreonHelper.app $R/ScreonHelper.app
ditto -c -k --keepParent $R/ScreonHelper.app $R/ScreonHelper.zip
xcrun notarytool submit $R/ScreonHelper.zip --keychain-profile "$NOTARY_PROFILE" --wait   # status: Accepted
xcrun stapler staple $R/ScreonHelper.app
SIGN_IDENTITY="$SIGN_IDENTITY" scripts/make-helper-dmg.sh $R/ScreonHelper.app $R/ScreonHelper-<marketing>.dmg
xcrun notarytool submit $R/ScreonHelper-<marketing>.dmg --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple $R/ScreonHelper-<marketing>.dmg
spctl -a -vv $R/ScreonHelper.app                                                        # source=Notarized Developer ID
spctl -a -t open --context context:primary-signature -vv $R/ScreonHelper-<marketing>.dmg
```
4. Install (only when asked). Quit the running helper first, replace, relaunch, and watch that it stays up with no new crash report:
```bash
osascript -e 'tell application id "com.ledinhcuong.screon.helper" to quit'; sleep 2; pkill -x ScreonHelper
MNT=$(hdiutil attach -nobrowse -readonly $R/ScreonHelper-<marketing>.dmg | tail -1 | awk -F'\t' '{print $NF}')
rm -rf /Applications/ScreonHelper.app && ditto "$MNT/ScreonHelper.app" /Applications/ScreonHelper.app; hdiutil detach -quiet "$MNT"
open /Applications/ScreonHelper.app; sleep 30; pgrep -x ScreonHelper
ls ~/Library/Logs/DiagnosticReports | grep -c ScreonHelper      # compare with the count before
```
   Delete the unpacked `ScreonHelper.app` copies in `$SCR` afterwards: a second copy with the same bundle id confuses Launch
   Services and Spotlight (`lsregister -u <path>` removes a stale registration).
5. Signing the update manifest, the GitHub Release and the tag are separate steps in the `release` skill, only on request.

## Report

Say what was built, the version (build), where the artifact is, the upload or notarization result, and what was **not** run
(real device, real Mac, a real tailnet). Never print signing material or the notary profile's credentials.
