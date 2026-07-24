# 01 — Policy + red/green harness

Type: task  
Status: resolved  
Blocked by: None — can start immediately

## What to build

A pure decision surface for system-lock preempt (when to auto-lock, when to warn on race-loss, that auto-locks force keep-awake) plus a script harness that goes red if those rules or the never-trap session table regress — without Touch ID or a real shield.

## Acceptance criteria

- [x] Pure policy API covers: idle crossed while unlocked+enabled → auto-lock; already locked → ignore; setting off → ignore; system lock while unlocked+enabled+not just auto-locked → warn once; system unlock while Medusa locked → release (existing).
- [x] Script harness exits 0 on green, 1 on red; runnable as `swift scripts/…`.
- [x] Never-trap rules from unlock-trap remain asserted (no reaffirm over system lock).

## Answer

Added `LockPolicy.idlePreempt` / `chordPreempt` / `shouldWarnRaceLoss` / `shouldHoldKeepAwake`. Harness: `scripts/system-lock-preempt-loop.swift` — 32 cases GREEN.
