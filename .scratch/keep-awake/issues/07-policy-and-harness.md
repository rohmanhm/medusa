# 07 — Policy + red/green harness

**What to build:** the pure decision surface for Keep Awake (start/extend/stop, deadline-passed-on-wake, Battery guard trip, Awake-level max-wins, menu-header derivation, hotkey-while-locked ignore, Lock-hold composition) plus a script harness that goes red without a GUI, mirroring the LockPolicy + unlock-trap / preempt loop pattern.

**Blocked by:** None — can start immediately (spec is ready).

**Status:** resolved

- [x] Pure policy covers all spec Testing Decisions cases (deadlines, guard percent + Final-warning on battery vs AC, level resolution, header strings, lock composition)
- [x] Script harness exits 0 on green / 1 on red, runnable headless as `swift scripts/keep-awake-loop.swift`
- [x] Never-trap + preempt forced-hold rules remain asserted (no regression)

## Answer

Done 2026-09-07 (goal execution): `KeepAwakePolicy` pure enum (resolveLevel max-wins, deadlinePassed, endReason battery-first, batteryShouldTrip percent-OR-Final, start/hotkey gating, header + `1:23` countdown derivation) + `scripts/keep-awake-loop.swift` (52 cases GREEN: policy mirror + production-source contracts for engine/menu/settings/notifier/app wiring). Never-trap + preempt harnesses still GREEN (42 + 33).
