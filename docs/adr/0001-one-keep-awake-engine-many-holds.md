# ADR-0001: One keep-awake engine, many Holds

The Lock owned its own power assertion while Sessions need their own keep-awake promise; two independent assertions would be two sources of truth that can disagree (Session ends under Lock, lock toggles under Session). So a single KeepAwakeController holds the OS assertion while any Hold is live — user Sessions plus the Lock hold the Lock places while engaged — and the Lock stops owning PowerAssertion.

## Considered Options

- Per-feature assertions (Lock owns one, Sessions own another): simplest migration, but end/reaffirm races and `pmset` shows two overlapping claims with no max-wins level resolution.
- Lock adopts the Session horizon (locking extends/ends the Session): silently rewrites a promise the user made via the other feature's UI.
- Chosen: one engine, many Holds, strongest Awake level wins, menu shows every live Hold.

## Consequences

Lock-only behavior must be preserved byte-for-byte through the migration (Keep Awake toggle, preempt forced hold, once-per-lock failure alert, reaffirm on wake) — the verify ticket proves it. The assertion wrapper becomes level-aware (two IDs, kernel timeout, held-tracked-from-deadline) behind the same begin/reaffirm/end shape so SelfTest and the Lock call sites migrate without new seams.
