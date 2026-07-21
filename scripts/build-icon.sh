#!/usr/bin/env bash
#
# Regenerates the prebuilt app-icon artifacts (Resources/AppIcon/) from the
# Icon Composer source document (Resources/Medusa.icon).
#
# The .icon document is the single source of truth: it carries the light and
# dark appearances (macOS 26+ picks them up from Assets.car), and actool also
# emits the classic .icns used as a fallback on older systems.
#
# Requires a full Xcode install (actool). Regular builds never need this —
# build-app.sh just copies the checked-in artifacts.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/Resources/AppIcon"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "==> actool: compiling Resources/Medusa.icon"
xcrun actool "$ROOT/Resources/Medusa.icon" \
	--compile "$TMP" \
	--platform macosx \
	--minimum-deployment-target 13.0 \
	--app-icon Medusa \
	--output-partial-info-plist "$TMP/partial.plist" >/dev/null

mkdir -p "$OUT"
cp "$TMP/Assets.car" "$TMP/Medusa.icns" "$OUT/"

echo "Updated: $OUT/Assets.car, $OUT/Medusa.icns"
