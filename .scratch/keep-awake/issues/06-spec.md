# Spec: Keep Awake sessions

Type: grilling
Status: resolved
Blocked by: 01, 02, 03, 05

## Answer

Done 2026-09-07 (goal execution, to-spec): wrote [../spec.md](../spec.md) (`Status: ready-for-agent`) from charting decisions 1–15 + all four research findings + ticket 05's deferral, using CONTEXT.md vocabulary exactly. Wrote [docs/adr/0001-one-keep-awake-engine-many-holds.md](../../../docs/adr/0001-one-keep-awake-engine-many-holds.md). Where research contradicted charting, research won (recorded in spec Further Notes: notification invariant + no start/stop notifs + ending-soon default off; `1:23` minute-boundary countdown; guard percent OR Final; hotkey unassigned; right-click Quick start; editable presets + 12 h; hardcoded deadline with sleep-honest copy; two assertion IDs + timeout + held-from-deadline). Implementation slicing graduates in the to-tickets step (07+).

## Question

Write `../spec.md` for Keep Awake sessions in the repo's spec shape (see `.scratch/system-lock-preempt/spec.md`: Problem Statement · Solution · User Stories · Implementation Decisions · Testing Decisions · Out of Scope · Further Notes), turning the [map](../map.md)'s charting decisions 1–15 plus the four research findings into a `ready-for-agent` document. It must:

1. Use `CONTEXT.md` vocabulary exactly (Keep Awake · Hold · Session · Lock hold · End condition · Awake level · Preset · Battery guard).
2. Pin the **engine**: `KeepAwakeController` owning `PowerAssertion` (now level-aware, with the IOKit timeout from research 01), the Hold set, deadline handling across sleep (research 03), and `LockController` placing/withdrawing the Lock hold instead of owning the assertion — preserving byte-for-byte today's behavior for lock-only users (`keepAwake` toggle, preempt's forced hold, `onKeepAwakeFailed` once per lock, `reaffirm` on wake).
3. Pin the **policy seam**: `KeepAwakePolicy` pure enum (start/extend/stop, deadline passed on wake, battery guard, level resolution across Holds, hotkey while locked → ignore) + `scripts/keep-awake-loop.swift` red/green harness, mirroring `LockPolicy` + `unlock-trap-loop.swift`.
4. Pin the **surfaces**: menu structure (decision 11, ASCII mock), status icon states, countdown option, `Until…`/`Custom…` presentation (research 03), the new **Keep Awake** Settings tab (decision 14 — including moving "Keep Mac awake while locked" out of Lock Screen, tab size, `@AppStorage` keys and `registerDefaults` entries), the second hotkey via `ShortcutRecorder`, notifications with Extend action (decision 10), Battery guard (decision 9), start-at-launch (decision 8).
5. Fold in [ticket 05](05-while-running-in-v1.md)'s answer on "while running".
6. Testing: policy harness cases, `--self-test` still PASS (extend it to hold/release both levels and prove via `pmset -g assertions`), a `--keepawake-test N` CLI mode analogous to `--lock-test`, and the HITL verify checklist.
7. Write **ADR-0001 "One keep-awake engine, many Holds"** in `docs/adr/` (format: `~/.claude/skills/domain-modeling/ADR-FORMAT.md`) — the Lock no longer owning the assertion is the surprising, hard-to-reverse, traded-off decision.
8. Close by **graduating the fog**: replace the map's "Implementation slicing" line with numbered implementation/verify/ship tickets (`07-…` onward) as child issues with `Blocked by` wiring; ship tickets are HITL.

**Delegated** (map Notes): the agent resolves this ticket alone. Where a research finding contradicts a charting decision, follow the research, change the decision line in the map, and say so in `## Answer`.
