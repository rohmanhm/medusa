# Ship the stage-1 release (safe defaults)

Type: task
Status: resolved
Blocked by: 03

## Question

HITL: release the burn-in-safe defaults as their own version (charting decision: stage 1 ships before stage 2). Follow the auto-updater pipeline — `release.sh`, DMG for humans + zip for Sparkle, publish order release-asset-first / appcast-second (see [auto-updater ship ticket](../../auto-updater/issues/06-ship-and-prove.md)). Commits, tags, `gh release create`, and the appcast push all wait for explicit approval.

Resolved when the release is live and an older build updates into it.

## Answer

Shipped in **v0.2.2** (2026-07-21) on the user's explicit approval. Note: the two-release plan collapsed — stage 1 and stage 2 went out together in one changeset (the Settings surface drives the stage-1 mechanism, so they're interdependent). The user chose a patch bump (0.2.2) over 0.3.0.

Pipeline ran clean: `release.sh 0.2.2` → Developer-ID sign → both zip + DMG notarized "Accepted", stapled, validated → appcast appended (build 9, EdDSA-signed, `length` matches the uploaded asset). Published asset-first (`gh release create v0.2.2`, tag at feature commit `290b14c`), then appcast pushed to `main`. Live feed at `raw.githubusercontent.com/rohmanhm/medusa/main/appcast.xml` advertises 0.2.2/9; enclosure URL returns 200.

**Residual HITL**: the true end-to-end Sparkle self-update (launch the installed 0.2.1 → "Check for Updates…" → it pulls 0.2.2) is unverified here — it needs an interactive update dialog. All the preconditions are proven (feed live, build 9 > 7, minSystem 13.0, signature valid, asset resolves).
