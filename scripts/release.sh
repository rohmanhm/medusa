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
MEDUSA_SIGN_IDENTITY="$IDENTITY" MEDUSA_VERSION="$VERSION" "$ROOT/scripts/build-app.sh" release

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

echo ""
echo "Release artifact: $ZIP"
echo "Publish with:     gh release create v$VERSION \"$ZIP\" --title \"Medusa $VERSION\" --generate-notes"
