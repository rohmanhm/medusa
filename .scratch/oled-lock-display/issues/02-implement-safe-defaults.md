# Implement burn-in-safe defaults on the shield

Type: task
Status: resolved
Blocked by: 01

> Goal-override execution (2026-07-21): built inline per [spec.md](../spec.md) §Stage 1.

## Question

Implement the mechanism recommended by [Burn-in mitigation research](01-burn-in-research.md) in `ShieldContentView` / `ShieldController`, **on by default for everyone** (charting decision — no OLED detection). Open questions this ticket settles in passing:

- How the motion coexists with the constraint-centered stack (animate constraints, transform the layer, or reposition on a timer) — and that it survives the auth-level drop and screen-parameter rebuilds.
- Multi-display behavior: each screen's content view moves independently or in lockstep (agent decides; note the choice in the answer).
- Whether dimming ships in the stage-1 default (per research findings).
- Internal pref keys registered now vs deferred to stage 2 — keep the settings surface untouched this stage; stage 2 ([04](04-settings-surface.md)) exposes the knobs.

Done when: build passes, `--self-test` passes, and the motion is visible on a local lock. No commits without approval.

## Answer

Implemented 2026-07-21 (goal-override execution), exactly per the research numbers:

- **Where**: `ShieldContentView` owns the whole mechanism — zigzag drift (83/521-min periods, 32×48 pt box clamped to ≤5% of the smaller screen dimension, wall-clock phase so re-locks continue the pattern), minute-boundary steps animated 1 s ease-in-out on the center-constraint constants, plus the 10-min dim timer (stack alpha ×0.5 over 2 s ease-out, hint hidden). `ShieldController.setAuthMode` forwards to the content views: `true` un-dims in 0.15 s and pauses the grace timer, `false` (canceled auth) re-arms it — zero new `LockController` wiring.
- **Multi-display**: per-screen content views share the wall-clock phase (lockstep — wear is per-panel, so per-screen decorrelation adds nothing) while clamping amplitudes per screen.
- **Prefs**: `shieldMotionStyle` ("drift" default) + `shieldDimMinutes` (10 default) registered now; [ticket 04](04-settings-surface.md) exposed them in the same push. Wander (15-min random relocation in the central 60%, 3 s crossfade) shipped as the opt-in style.
- **Verified**: clean build; `--self-test` PASS on 2 displays; `--snapshot-shield` now logs stack geometry per variant — drift phase deltas match the zigzag model exactly (32.0 pt X between phases 0 and 41.5 min; live variant matches the model at its run timestamp to <1 pt), dimmed variant renders at alpha 0.5 with the hint gone, wander origins are random within the central-60% box, `off` restores the exact static center (752.5, 450.0 on the 1728×1080 reference).
- **Residual for [ticket 03](03-verify-on-oled.md)**: un-dim during a *real* auth attempt, hot-plug rebuild behavior, and the felt sub-perceptibility on the OLED itself.
