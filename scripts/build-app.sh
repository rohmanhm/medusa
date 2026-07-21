#!/usr/bin/env bash
#
# Builds Medusa and assembles a runnable, ad-hoc-signed .app bundle.
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
APP="$ROOT/build/Medusa.app"

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
cp "$BIN" "$APP/Contents/MacOS/Medusa"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

# App icon: Assets.car carries the light/dark appearances (macOS 26+),
# Medusa.icns is the classic fallback. Regenerate via scripts/build-icon.sh.
cp "$ROOT/Resources/AppIcon/Assets.car" "$APP/Contents/Resources/Assets.car"
cp "$ROOT/Resources/AppIcon/Medusa.icns" "$APP/Contents/Resources/Medusa.icns"

IDENTITY="${MEDUSA_SIGN_IDENTITY:-}"
if [[ -n "$IDENTITY" ]]; then
	echo "==> signing with stable identity ($IDENTITY) — TCC grants will persist"
	codesign --force --options runtime --sign "$IDENTITY" "$APP"
else
	echo "==> ad-hoc signing (re-grant permissions after each rebuild; see header to make them persist)"
	codesign --force --sign - "$APP"
fi

echo ""
echo "Built: $APP"
echo "Run:   open \"$APP\"    (or double-click it in Finder)"
