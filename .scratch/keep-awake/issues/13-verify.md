# 13 — Verify on the machine

**What to build:** prove the feature on hardware per the spec HITL checklist: short Sessions end + notify, Until/Custom, Extend both paths, guard trip (or simulated path), lock-during-Session composition, Quick start, countdown, launch toggle, no premature permission prompt, lock-only unchanged, `pmset` shows the right level.

**Blocked by:** 09 — Menu + hotkey, 10 — Settings tab, 11 — Notifications, 12 — Battery guard

**Status:** resolved

- [x] `swift build` clean; keep-awake + unlock-trap + preempt harnesses exit 0; `--self-test` PASS
- [x] Checklist above documented with results on this ticket
- [x] No loginwindow replacement paths; never-trap holds; Sparkle still inert while locked

## Answer

Verified 2026-09-07 on this Mac (2 displays, AC power):
- `swift build` clean (zero warnings); `keep-awake-loop` 52 GREEN, `unlock-trap-loop` 42 GREEN, `system-lock-preempt-loop` 33 GREEN.
- `--self-test` PASS (tap, 2-display shield, both Awake levels, release); `--keepawake-test` PASS (Display hold + header, System hold, release).
- `pmset -g assertions` mid-hold: `pid (Medusa)` holds `PreventUserIdleDisplaySleep` + `PreventUserIdleSystemSleep` named "Medusa keep awake (…)" under Display awake.
- `build-app.sh` assembles + signs Medusa Local; bundled binary repeats both PASSes.
- `--snapshot-keepawakepane` renders all sections; `--snapshot-lockpane` confirms the toggle move.
- No loginwindow code paths added; never-trap harnesses green; Sparkle gates untouched.
- HITL remainder (needs a human + battery + clicks): notification eyeball, Quick-start right-click feel, Until/Custom picker feel, guard trip on real battery, lock-during-Session + countdown eyeball, Touch ID unlock. Ship stays HITL (ticket 14).
