#!/usr/bin/env bash
#
# Signs a release zip with the Sparkle EdDSA key (login keychain) and appends
# the matching <item> to the appcast. Normally invoked by release.sh.
#
# Usage:
#   update-appcast.sh <version> <bundle-version> <zip-path> [appcast] [enclosure-url]
#
#   version        marketing version, e.g. 0.2.0
#   bundle-version CFBundleVersion of the built app (monotonic commit count)
#   zip-path       the final, notarized+stapled release zip
#   appcast        target file      (default: <repo>/appcast.xml)
#   enclosure-url  download URL     (default: the GitHub Release asset URL)
#
# The Sparkle tools ship inside the SPM artifact, version-pinned to the
# framework — run a swift build first if .build/artifacts is missing.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${1:?usage: update-appcast.sh <version> <bundle-version> <zip-path> [appcast] [enclosure-url]}"
BUILD="${2:?missing bundle-version}"
ZIP="${3:?missing zip-path}"
APPCAST="${4:-$ROOT/appcast.xml}"
URL="${5:-https://github.com/rohmanhm/medusa/releases/download/v$VERSION/Medusa-$VERSION.zip}"

SIGN_UPDATE="$ROOT/.build/artifacts/sparkle/Sparkle/bin/sign_update"
[[ -x "$SIGN_UPDATE" ]] || { echo "error: $SIGN_UPDATE not found — run swift build first" >&2; exit 1; }
[[ -f "$ZIP" ]] || { echo "error: zip not found: $ZIP" >&2; exit 1; }

if grep -q "<sparkle:shortVersionString>$VERSION<" "$APPCAST"; then
	echo "error: $APPCAST already has an item for $VERSION — remove it first to re-release" >&2
	exit 1
fi

echo "==> signing $ZIP with the Sparkle EdDSA key"
SIGNATURE="$("$SIGN_UPDATE" "$ZIP")"   # sparkle:edSignature="…" length="…"
[[ "$SIGNATURE" == *edSignature* ]] || { echo "error: unexpected sign_update output: $SIGNATURE" >&2; exit 1; }

PUBDATE="$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')"
ITEM="        <item>
            <title>Version $VERSION</title>
            <pubDate>$PUBDATE</pubDate>
            <sparkle:version>$BUILD</sparkle:version>
            <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
            <sparkle:releaseNotesLink>https://github.com/rohmanhm/medusa/releases/tag/v$VERSION</sparkle:releaseNotesLink>
            <enclosure url=\"$URL\" $SIGNATURE type=\"application/octet-stream\"/>
        </item>"

LINE="$(grep -n '</channel>' "$APPCAST" | head -1 | cut -d: -f1)"
[[ -n "$LINE" ]] || { echo "error: no </channel> in $APPCAST" >&2; exit 1; }

TMP="$(mktemp)"
head -n "$((LINE - 1))" "$APPCAST" > "$TMP"
printf '%s\n' "$ITEM" >> "$TMP"
tail -n "+$LINE" "$APPCAST" >> "$TMP"
mv "$TMP" "$APPCAST"

echo "==> appended $VERSION (build $BUILD) to $APPCAST"
