#!/usr/bin/env bash
#
# One-command notarized release:
#   build → Developer ID sign → notarize → staple → re-zip → verify
#
# Usage:
#   ./scripts/release.sh 0.1.1
#
# Produces build/Medusa-<version>.zip — the artifact to upload to the GitHub
# release. Users who download it see no Gatekeeper malware warning.
#
# One-time prerequisites:
#   - A "Developer ID Application" certificate in the login keychain
#     (Xcode → Settings → Accounts → Manage Certificates → + → Developer ID Application)
#   - Stored notarization credentials:
#       xcrun notarytool store-credentials medusa-notary \
#         --apple-id <apple-id-email> --team-id <team-id> \
#         --password <app-specific-password>
#
# Overrides:
#   MEDUSA_RELEASE_IDENTITY  signing identity (default: first "Developer ID
#                            Application" identity found in the keychain)
#   MEDUSA_NOTARY_PROFILE    notarytool keychain profile (default: medusa-notary)

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${1:?usage: release.sh <version>   e.g. release.sh 0.1.1}"
APP="$ROOT/build/Medusa.app"
ZIP="$ROOT/build/Medusa-$VERSION.zip"
PROFILE="${MEDUSA_NOTARY_PROFILE:-medusa-notary}"

IDENTITY="${MEDUSA_RELEASE_IDENTITY:-$(
	security find-identity -v -p codesigning \
		| awk -F '"' '/Developer ID Application/ {print $2; exit}'
)}"
if [[ -z "$IDENTITY" ]]; then
	echo "error: no 'Developer ID Application' identity in the keychain — see prerequisites in this script's header" >&2
	exit 1
fi

echo "==> release $VERSION, signing as: $IDENTITY"
MEDUSA_RELEASE=1 MEDUSA_SIGN_IDENTITY="$IDENTITY" MEDUSA_VERSION="$VERSION" \
	"$ROOT/scripts/build-app.sh" release

# Catch a broken signature seal locally instead of after a 5-minute notary
# round-trip (Sparkle's nested helpers make the seal easier to get wrong).
echo "==> verifying signature seal"
codesign --verify --deep --strict --verbose=2 "$APP"

echo "==> zipping for notarization"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "==> submitting to Apple notary service (usually 1-5 min)"
SUBMIT_OUT="$(xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait --timeout 15m 2>&1 | tee /dev/stderr)"
SUBMISSION_ID="$(awk '/^  id: /{print $2; exit}' <<<"$SUBMIT_OUT")"
STATUS="$(awk '/status:/{s=$2} END{print s}' <<<"$SUBMIT_OUT")"
if [[ "$STATUS" != "Accepted" ]]; then
	echo "error: notarization status '$STATUS' — fetching log:" >&2
	[[ -n "$SUBMISSION_ID" ]] && xcrun notarytool log "$SUBMISSION_ID" --keychain-profile "$PROFILE" >&2
	exit 1
fi

# The ticket can only be stapled to the .app, never to a zip — so staple,
# then rebuild the zip from the stapled app.
echo "==> stapling ticket and re-zipping"
xcrun stapler staple "$APP"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "==> verifying"
spctl -a -vv "$APP"
xcrun stapler validate "$APP"

# DMG for human downloads: no extraction step, so third-party unzip tools
# can't mangle the Sparkle framework symlinks (which breaks the seal and
# makes Gatekeeper reject a perfectly notarized app). The zip stays as the
# Sparkle enclosure — Sparkle extracts with its own correct code.
DMG="$ROOT/build/Medusa-$VERSION.dmg"
DMG_STAGE="$ROOT/build/dmg-staging"
echo "==> building DMG"
rm -rf "$DMG_STAGE" "$DMG"
mkdir -p "$DMG_STAGE"
ditto "$APP" "$DMG_STAGE/Medusa.app"
ln -s /Applications "$DMG_STAGE/Applications"
hdiutil create -volname "Medusa" -srcfolder "$DMG_STAGE" -ov -format UDZO -quiet "$DMG"
rm -rf "$DMG_STAGE"
codesign --force --sign "$IDENTITY" "$DMG"

echo "==> notarizing DMG (contents are already notarized — usually quick)"
DMG_OUT="$(xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait --timeout 15m 2>&1 | tee /dev/stderr)"
DMG_ID="$(awk '/^  id: /{print $2; exit}' <<<"$DMG_OUT")"
DMG_STATUS="$(awk '/status:/{s=$2} END{print s}' <<<"$DMG_OUT")"
if [[ "$DMG_STATUS" != "Accepted" ]]; then
	echo "error: DMG notarization status '$DMG_STATUS' — fetching log:" >&2
	[[ -n "$DMG_ID" ]] && xcrun notarytool log "$DMG_ID" --keychain-profile "$PROFILE" >&2
	exit 1
fi
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"
"$ROOT/scripts/update-appcast.sh" "$VERSION" "$BUILD_NUMBER" "$ZIP"

echo ""
echo "Release artifacts: $DMG (humans)"
echo "                   $ZIP (Sparkle enclosure)"
echo ""
echo "Publish — order matters (the appcast must go live only after the asset exists):"
echo "  1. gh release create v$VERSION \"$DMG\" \"$ZIP\" --title \"Medusa $VERSION\" --generate-notes"
echo "  2. git add appcast.xml && git commit -m 'chore: appcast for $VERSION' && git push"
echo ""
echo "Installed apps see the update once step 2's push lands on main."
