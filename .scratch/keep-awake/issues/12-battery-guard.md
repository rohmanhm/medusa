# 12 — Battery guard

**What to build:** the Sessions-only Battery guard (default on): on-battery trip at ≤ threshold OR OS Final warning, ending Sessions with the ended notification; never on AC; threshold customizable.

**Blocked by:** 08 — Engine + assertion refactor + Lock-hold migration

**Status:** resolved

- [x] Guard trips on either condition on battery, never on AC; ended notification fires with battery reason
- [x] Guard off respects the toggle; threshold edits apply live
- [x] Lock hold explicitly NOT covered (deferred post-v1 per spec)

## Answer

Done 2026-09-07 (goal execution): guard lives in the engine tick (throttled 15 s + wake/clock re-read): `IOPSCopyPowerSourcesInfo` + providing-type + Current/Max percent + `IOPSGetBatteryWarningLevel() == kIOPSLowBatteryWarningFinal` (actual SDK symbol — `kIOPSBatteryWarningFinal` doesn't exist), policy `batteryShouldTrip` (enabled + onBattery + (percent<=threshold OR Final)); trips end the Session with the battery reason + ended notification. Never on AC; toggle/threshold live via defaults observation. Lock hold explicitly uncovered (spec). Live low-battery trip left to HITL (this machine is on AC).
