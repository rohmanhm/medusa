# 08 — Engine + assertion refactor + Lock-hold migration

**What to build:** the single KeepAwakeController engine owning the Hold set with deadline authority (≤1 s wall-clock tick + wake/clock-change re-evaluation), the level-aware assertion wrapper (two IDs, kernel timeout, Extend same-ID, held-from-deadline), and the Lock placing/withdrawing its Lock hold instead of owning the assertion — with lock-only behavior preserved byte-for-byte.

**Blocked by:** 07 — Policy + red/green harness

**Status:** resolved

- [x] Session lifecycle (indefinitely / duration→deadline / until-time) holds/releases the right Awake level, Extend re-arms
- [x] Lock hold path preserves today's toggle, preempt forced hold, once-per-lock failure alert, reaffirm on wake, yield/release
- [x] `--self-test` still PASS; both levels provable via `pmset` keyed on pid; `--keepawake-test N` CLI mode works
- [x] Unbundled paths stay notification-free (bundle-id guard invariant holds)

## Answer

Done 2026-09-07 (goal execution): `KeepAwakeController` (single active Session + Lock hold, 1 s wall-clock tick + didWake/clock-change/defaults re-evaluation, kernel timeout re-derived `deadline-now+60` on wake/Extend, indefinite/bare-lock holds timeout-free like today); `PowerAssertion` level-aware (Display = Display+System IDs, System = System ID, CreateWithProperties Timeout+TurnOff, Extend = SetProperty same ID); `LockController.keepAwakeEngine` hook (lock/reaffirm route through `setLockHold`/`reaffirmLockHold`, unlock withdraws, headless nil-path keeps `power.begin()` byte-for-byte). Verified: `--self-test` PASS (both levels), `--keepawake-test` PASS, `pmset` shows `pid (Medusa)` holding both named assertions under Display awake. Deliberate call: no timeout on indefinite/bare-lock holds (infinity can't be bounded; matches today's lock).
