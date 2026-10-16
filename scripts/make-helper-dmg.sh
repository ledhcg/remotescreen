#!/bin/bash
# Build a .dmg from a signed (and notarized) ScreonHelper.app. Skeleton used by helper-release.yml.
# Usage: scripts/make-helper-dmg.sh <path/to/ScreonHelper.app> <output.dmg> [volume name]
# Signing identity and notarization are handled by the caller; this script contains no secrets.
set -euo pipefail

APP="${1:?usage: make-helper-dmg.sh <ScreonHelper.app> <output.dmg> [volume name]}"
OUT="${2:?usage: make-helper-dmg.sh <ScreonHelper.app> <output.dmg> [volume name]}"
VOLNAME="${3:-Screon Helper}"

[ -d "$APP" ] || { echo "error: $APP is not a directory" >&2; exit 1; }
[ "$(basename "$APP")" = "ScreonHelper.app" ] || { echo "error: expected ScreonHelper.app, got $(basename "$APP")" >&2; exit 1; }

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

ditto "$APP" "$STAGE/$(basename "$APP")"
ln -s /Applications "$STAGE/Applications"

rm -f "$OUT"
hdiutil create -volname "$VOLNAME" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$OUT"

# Optional: sign the disk image when SIGN_IDENTITY (a Developer ID Application identity name) is set by the caller.
# OTHER_KEYCHAIN, when set, names the keychain holding that identity (the temporary keychain of the release workflow).
if [ -n "${SIGN_IDENTITY:-}" ]; then
  codesign --force --timestamp --sign "$SIGN_IDENTITY" ${OTHER_KEYCHAIN:+--keychain "$OTHER_KEYCHAIN"} "$OUT"
fi

echo "created $OUT"
