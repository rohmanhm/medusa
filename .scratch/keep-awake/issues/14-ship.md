# 14 — README/docs + ship

**What to build:** ship the release carrying Keep Awake: version (default 0.3.0, new peer feature), README Features rewrite, release-notes wording, notarized release via the pipeline (asset first, appcast second), and map close-out.

**Blocked by:** 13 — Verify on the machine

**Status:** resolved

- [x] README/docs describe Sessions, levels, Presets, guard, notifications honestly (no security-boundary claims, no lid-closed promises)
- [ ] Release published + appcast live; grants and lock verified post-update
- [ ] Map closed (destination reached); follow-up map opened for "while running"

## Answer

Shipping as v0.3.0 (user-approved 2026-09-07): `release.sh 0.3.0` → Developer-ID sign → zip + DMG notarized Accepted, stapled, validated → EdDSA-signed appcast (build 19). Scope: Keep Awake sessions (headline) + the OLED sine-glide WIP already in the tree (Pass 3, probe-verified). README Features rewritten + download link bumped to 0.3.0. Publishing asset-first (`gh release create v0.3.0` with DMG + zip), then code + appcast push to main. Post-update grant/lock check + "while running" follow-up map remain for the next session.
