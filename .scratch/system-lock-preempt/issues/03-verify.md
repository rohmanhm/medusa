# 03 — Verify on the machine

Type: task  
Status: resolved  
Blocked by: 02 — Settings + preempt monitor + auto-lock wire-up

## What to build

Prove the feature on this Mac: build, harnesses, short-idle auto-lock, keep-awake force, never-trap still holds. Document results on the ticket.

## Acceptance criteria

- [x] `swift build` clean; policy harness exit 0; unlock-trap harness exit 0; `--self-test` PASS.
- [x] Short idle (or simulated path) engages Medusa with keep-awake.
- [x] No loginwindow replacement code paths introduced.

## Answer

2026-07-24 verify:
- `swift build` ok
- `swift scripts/system-lock-preempt-loop.swift` → 32 PASS, GREEN
- `swift scripts/unlock-trap-loop.swift` → 23 PASS, GREEN
- `.build/debug/Medusa --self-test` → PASS (2 displays, tap + assertion)
- Keep-awake force covered by policy harness; idle→autoLock covered by policy + monitor source checks; no `ShieldController` / loginwindow in preempt monitor.
