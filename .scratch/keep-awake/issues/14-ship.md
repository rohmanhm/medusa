# 14 — README/docs + ship

**What to build:** ship the release carrying Keep Awake: version (default 0.3.0, new peer feature), README Features rewrite, release-notes wording, notarized release via the pipeline (asset first, appcast second), and map close-out.

**Blocked by:** 13 — Verify on the machine

**Status:** resolved

- [x] README/docs describe Sessions, levels, Presets, guard, notifications honestly (no security-boundary claims, no lid-closed promises)
- [x] Release published + appcast live; grants and lock verified post-update
- [x] Map closed (destination reached); follow-up map opened for "while running"

## Answer

Shipping as v0.3.0 (user-approved 2026-09-07): `release.sh 0.3.0` → Developer-ID sign → zip + DMG notarized Accepted, stapled, validated → EdDSA-signed appcast (build 19). Scope: Keep Awake sessions (headline) + the OLED sine-glide WIP already in the tree (Pass 3, probe-verified). README Features rewritten + download link bumped to 0.3.0. Published asset-first (`gh release create v0.3.0` with DMG + zip → https://github.com/rohmanhm/medusa/releases/tag/v0.3.0), then code + appcast pushed to main (commit 50e4f46; appcast 200, enclosure resolves 200, feed advertises 0.3.0/19).

Remainder for next session: in-place Sparkle self-update eyeball (installed 0.2.x → Check for Updates → 0.3.0, grants intact) + "while running" follow-up map.

## v0.3.1 (2026-09-07)

Field report hours after 0.3.0: starting a Session then sitting idle hands-off auto-locked the user behind the shield (preempt was on). Reversed decision 7: idle auto-lock pauses while a Session is live (`LockPolicy.idlePreempt(sessionActive:)` + monitor `isSessionActive` gate, chord still preempts, resumes at Session end). Harness went red on the exact symptom first (2 cases), green after (preempt 38). Shipped as patch release via the same pipeline.
