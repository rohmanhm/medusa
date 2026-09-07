# 11 — Notifications + Extend

**What to build:** end-of-session notifications only for un-chosen ends (elapsed / time-passed incl. sleep-honest copy / battery / process-ended placeholder) with Extend action, the opt-in ending-soon nudge, first-Session permission request, and the denial fallback (menu-only + one latched explanation).

**Blocked by:** 08 — Engine + assertion refactor + Lock-hold migration

**Status:** resolved

- [x] Never notifies on start/manual Stop; ended-notification fires with reason + `Your Mac will sleep on its normal schedule.`
- [x] Extend works from notification and menu; delegate + categories at launch, `willPresent` implemented, no provisional
- [x] Bundle-id guard invariant: zero notification-center touches when unbundled; all CLI/self-test/snapshot paths trap-free

## Answer

Done 2026-09-07 (goal execution): `KeepAwakeNotifier` (bundle-id guard invariant — every entry checks `available`, unbundled paths provably trap-free via `--self-test`/`--keepawake-test`/snapshots all PASS headless); delegate + category registered at launch, auth deferred to first Session start, `willPresent` banner+list+sound, no provisional; ended posts only for un-chosen ends with reason + `Your Mac will sleep on its normal schedule.`, soon-nudge (default off) carries Extend-30; AppDelegate handles the Extend action. Denial fallback = menu Extend (guaranteed path). Live notification eyeball left to HITL (ticket 13).
