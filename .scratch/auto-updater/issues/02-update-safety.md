# Update safety: TCC grants and the engaged lock

Type: research
Status: resolved

## Question

Is an in-place Sparkle update safe for a TCC-bound input-lock app — and what must the updater never do?

- **TCC persistence**: do the Accessibility + Input Monitoring grants survive a Sparkle in-place update? TCC keys grants to bundle ID + code-signing designated requirement — confirm that same-Developer-ID, same-bundle-ID updates keep grants, and enumerate exactly what breaks them (cert/team change, bundle-id change, DevID→ad-hoc downgrade, changed designated requirement). Peer evidence: do Rectangle/AltTab updates re-prompt for Accessibility? Any issue-tracker scar tissue?
- **Never update under lock**: Medusa must never install/relaunch while the shield is up (the relaunch would tear down the event tap and the lock). Which `SPUUpdaterDelegate` hooks gate this — session-in-progress checks, `updater(_:shouldPostponeRelaunchForUpdate:untilInvoking:)` or equivalent in current Sparkle 2 API — and what's the recommended pattern for "app is busy, defer everything"?
- **Dev builds**: local `build-app.sh` builds are ad-hoc signed with the same bundle ID. Should the updater be compiled out / disabled there (an ad-hoc build "updating" to a DevID build would churn TCC; Sparkle also validates the update's signing against the running app)? How do peers gate Sparkle off in debug/dev builds?
- **Install privileges**: Medusa lives in `/Applications` (user-dragged). When does Sparkle 2 need an authorization prompt vs updating silently (ownership, root-owned dirs), and does that interact with LSUIElement?

Findings file: `.scratch/auto-updater/research/02-update-safety.md`

## Answer

In-place Sparkle updates are safe: TCC keys grants to bundle ID + the signed designated requirement (TN3127), so same-bundle-ID, same-Developer-ID-team releases keep Accessibility + Input Monitoring with no re-prompt — peers (Rectangle/AltTab/Ice/Maccy) show zero re-prompt reports for normal Sparkle updates. Grants break on team/cert change (worst case: stale "granted" checkbox that silently denies — the Bartender incident), bundle-ID change, or any ad-hoc build (cdhash-pinned DR, churns every rebuild). The "inert while locked" guard is four Sparkle 2 layers keyed off `LockController.isLocked`: veto checks in `updater(_:mayPerform:)` (throws), defer scheduled-update UI via gentle reminders (`standardUserDriverShouldHandleShowingScheduledUpdate`), stall on-quit installs in `willInstallUpdateOnQuit` (return true, hold the block), and back-stop relaunch with `updaterShouldRelaunchApplication` — the old Sparkle 1 hooks are deprecated. Surprise: Sparkle's validator would *accept* an ad-hoc→DevID update (EdDSA branch), so dev builds must not start the updater at all — construct with `startingUpdater: false` and only `startUpdater()` in release-signed builds. User-owned /Applications installs update silently, no auth prompt. Full detail + sources: `.scratch/auto-updater/research/02-update-safety.md`.

## Comments
