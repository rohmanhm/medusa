#!/usr/bin/env bash
#
# Builds Medusa and assembles a runnable, ad-hoc-signed .app bundle.
#
# Identity: local by default, so day-to-day rebuilds never collide with a
# release install in System Settings → Privacy (TCC grants are keyed by
# bundle ID; the display name is what you see in the list).
#
#   ./scripts/build-app.sh                 → build/Medusa Local.app
#                                            org.medusa.Medusa.local
#   MEDUSA_RELEASE=1 ./scripts/build-app.sh → build/Medusa.app
#                                            org.medusa.Medusa
#
# release.sh always sets MEDUSA_RELEASE=1; you almost never need to set it
# by hand.
#
# Signing: ad-hoc by default (`codesign -s -`) — no prompts, always works, and
# is enough to run locally and receive the Accessibility / Input Monitoring TCC
# grants. The only cost is that the ad-hoc hash changes each build, so a rebuild
# forces you to re-grant the two permissions.
#
# If you rebuild often, sign with a stable identity instead so grants persist:
#   MEDUSA_SIGN_IDENTITY="Apple Development: You (TEAMID)" ./scripts/build-app.sh
# The first such build shows a one-time keychain prompt — click "Always Allow".
#
# For signed & notarized *release* builds (Developer ID + notarization), see the
# distribution research at .scratch/v1-spec/research/04-distribution.md.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${1:-release}"

# Local builds get a distinct identity so Privacy settings and TCC grants
# never mix with a production install. Release builds (release.sh) opt out.
if [[ "${MEDUSA_RELEASE:-}" == "1" ]]; then
	APP_NAME="Medusa"
	BUNDLE_ID="org.medusa.Medusa"
	DISPLAY_NAME="Medusa"
else
	APP_NAME="Medusa Local"
	BUNDLE_ID="org.medusa.Medusa.local"
	DISPLAY_NAME="Medusa Local"
fi
APP="$ROOT/build/${APP_NAME}.app"

echo "==> swift build -c $CONFIG"
cd "$ROOT"
swift build -c "$CONFIG"

BIN="$ROOT/.build/$CONFIG/Medusa"
if [[ ! -f "$BIN" ]]; then
	echo "error: build product not found at $BIN" >&2
	exit 1
fi

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"
mkdir -p "$APP/Contents/Frameworks"
cp "$BIN" "$APP/Contents/MacOS/Medusa"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

# Stamp the local/prod identity over the template plist. CFBundleExecutable
# stays "Medusa" — it names the binary on disk, not the product people see.
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName $DISPLAY_NAME" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $DISPLAY_NAME" "$APP/Contents/Info.plist"

# Sparkle: SwiftPM links the framework but never embeds it — copy the one it
# staged next to the binary (cp -R keeps the Versions/… symlinks, which the
# code signature requires). The XPC services are sandboxed-app-only; Medusa
# isn't sandboxed, so strip them BEFORE signing seals the bundle.
cp -R "$ROOT/.build/$CONFIG/Sparkle.framework" "$APP/Contents/Frameworks/"
rm -rf "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices"

# App icon: Assets.car carries the light/dark appearances (macOS 26+),
# Medusa.icns is the classic fallback. Regenerate via scripts/build-icon.sh.
cp "$ROOT/Resources/AppIcon/Assets.car" "$APP/Contents/Resources/Assets.car"
cp "$ROOT/Resources/AppIcon/Medusa.icns" "$APP/Contents/Resources/Medusa.icns"

# Release builds stamp the marketing version; CFBundleVersion must stay
# monotonic for Sparkle, so it's derived from the commit count.
if [[ -n "${MEDUSA_VERSION:-}" ]]; then
	echo "==> stamping version $MEDUSA_VERSION"
	/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $MEDUSA_VERSION" "$APP/Contents/Info.plist"
	/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(git -C "$ROOT" rev-list --count HEAD)" "$APP/Contents/Info.plist"
fi

# Inside-out signing (never --deep): Sparkle ships ad-hoc-signed, which both
# notarization and hardened-runtime library validation reject — every build
# must re-sign its nested helpers, then the framework, then the app, all with
# the same identity the app uses.
FW="$APP/Contents/Frameworks/Sparkle.framework"
IDENTITY="${MEDUSA_SIGN_IDENTITY:-}"
if [[ -n "$IDENTITY" ]]; then
	echo "==> signing with stable identity ($IDENTITY) — TCC grants will persist"
	codesign --force --options runtime --timestamp --sign "$IDENTITY" "$FW/Versions/B/Autoupdate"
	codesign --force --options runtime --timestamp --sign "$IDENTITY" "$FW/Versions/B/Updater.app"
	codesign --force --options runtime --timestamp --sign "$IDENTITY" "$FW"
	codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
else
	echo "==> ad-hoc signing (re-grant permissions after each rebuild; see header to make them persist)"
	codesign --force --sign - "$FW/Versions/B/Autoupdate"
	codesign --force --sign - "$FW/Versions/B/Updater.app"
	codesign --force --sign - "$FW"
	codesign --force --sign - "$APP"
fi

echo ""
echo "Built: $APP"
echo "       $DISPLAY_NAME  ($BUNDLE_ID)"
if [[ "${MEDUSA_RELEASE:-}" != "1" ]]; then
	echo "       local identity — shows as \"$DISPLAY_NAME\" in Privacy settings"
fi
echo "Run:   open \"$APP\"    (or double-click it in Finder)"
