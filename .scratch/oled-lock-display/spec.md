# Spec: OLED-safe lock display

Derived from [map.md](map.md) + [research/01-burn-in-mitigation.md](research/01-burn-in-mitigation.md). Two stages, one codebase change-set each; stage 1's mechanism ships **on by default for everyone**, stage 2 exposes the knobs.

## Problem

The lock shield holds a power assertion so the display stays lit for hours while showing a pixel-static stack (clock colon, date, message, hint) at up to ~89% emitted luminance. On OLED panels that is exactly the cumulative-static-content regime that produces burn-in (RTINGS). Nothing currently moves or dims.

## Stage 1 — burn-in-safe defaults

### Drift (always active while locked, default on)

AOSP-style sub-perceptual zigzag applied to the stack's `centerX`/`centerY` constraint constants in `ShieldContentView`:

- Two independent triangular waves of **wall-clock minutes** (`Date().timeIntervalSince1970 / 60`) — wall-clock, not per-lock elapsed, so repeated locks don't restart the pattern at the same origin and wear decorrelates across sessions.
- Periods: **X = 83 min, Y = 521 min** (incommensurate, AOSP `BurnInHelper.kt`) — the 2-D path never visibly repeats.
- Travel box: **X = 32 pt, Y = 48 pt**, centered on screen center (offset = zigzag − amplitude/2), each axis clamped to **≤5% of the smaller screen dimension** for unusual displays.
- Recomputed on the **minute boundary** of the existing 1 s tick; each step (~0.8 pt X / ~0.2 pt Y) animates over **1.0 s ease-in-out** (`NSAnimationContext` + `allowsImplicitAnimation` + `layoutSubtreeIfNeeded`).
- The initial offset is applied at view creation (phase = current wall time), not zero.
- The 1 s timer now runs whenever the clock/date is shown **or** motion is active with any visible content; a fully empty shield (everything toggled off) needs no timer and no motion.

### Dim-after-grace (default on, 10 min)

- One-shot timer from lock (view creation): after **10 min**, animate the whole stack's `alphaValue` **1.0 → 0.5** over **2.0 s ease-out** (multiplies every label's baked-in alpha by 0.5 ⇒ ~22–25% emitted luminance, ≥3× slower wear) and the hint label's alpha **→ 0** (fully static, nonessential).
- **Un-dim in 0.15 s** on interaction. Hook: `ShieldController.setAuthMode(true)` — fired by the first key/click via `LockController.beginAuth()` — forwards to every content view. `setAuthMode(false)` (canceled auth) restarts the grace timer. No new LockController wiring.
- Dimming applies regardless of motion style.

### Multi-display

Each screen's `ShieldContentView` computes its own clamped amplitudes but shares the wall-clock phase — screens step in lockstep (cheap, and per-screen decorrelation adds nothing: wear is per-panel, and each panel's own content moves).

## Stage 2 — Settings surface

New "Screen Protection" section in `LockScreenPane` (Settings → Lock Screen), following existing pane idioms (Picker rows + footer copy, like the backstop picker):

- **Motion** picker → `shieldMotionStyle` (String): `drift` "Subtle drift" (default) · `wander` "Wander" · `off` "Off".
  - **Wander** (opt-in, from the research): every **15 min** the stack fades out over **3 s**, relocates to a uniformly random point within the **central 60%** of the screen, fades back in over 3 s (DeskClock pattern). Strongest positional spread for overnight OLED locks.
- **Dim lock screen after** picker → `shieldDimMinutes` (Int): 2, 5, **10 (default)**, 15, 30 minutes · Never (0) — same collapse of toggle+timing the backstop picker uses.
- Footer explains the why: protects OLED displays; changes apply at the next lock (read-once-per-lock contract).
- Keys join `AppSettings.Keys` + `registerDefaults()`; typed accessors on `AppSettings` (`shieldMotion: ShieldMotionStyle`, `shieldDimDuration: TimeInterval`).

## Out of scope (map)

Clock format/size, static position choice, opacity slider, OLED auto-detection, themes.

**Preview** (amended 2026-07-21 at the user's request): `LockScreenPreview` plays a sped-up demo of the selected protection — drift compressed to 9/13-second zigzag periods, Wander relocating every 4 s with the fade-teleport-fade choreography, a 12-second dim/recover cycle when dimming is on — with a "Sped-up demo" caption. Honest speeds would be invisible in a 150 pt box.

**Perceptibility rework** (amended 2026-07-22, from a field report of "motion and dim didn't work"): stage-1's defaults were correct for burn-in but *unobservable*, so they read as broken. Changed: (1) **Wander is now the default** — it's the only plainly-visible motion, and the strongest positional spread; interval cut from 15 min to **2 min**, fade from 3 s to 1.4 s a side. (2) **Drift is now perceptible** — recomputed every tick off the fractional wall clock (continuous glide, not a once-a-minute hop), periods scaled 83/521 → **5/8 min**, travel box 32×48 → **120×80 pt** (clamped ≤10% of the smaller dimension). (3) **Dim default 10 → 5 min.** (4) **Protection notice** — a one-line "Screen protection · …" summary fades in on lock for a few seconds then fades away (transient, so nothing static burns in). (5) **Multi-display hardening** — `screensChanged` now ignores no-op notifications (by frame signature) and debounces the rest by 0.35 s, so an external display renegotiating HDMI/HDR can't tear the overlays down mid-storm. Snapshot runner gains a `motionOverride` seam and a real `wander` variant (the style had *no* prior coverage).

## Verification

- `swift build` clean; `./scripts/build-app.sh` assembles; `--self-test` PASS.
- `--snapshot-shield <dir>` extended to write three PNGs and log the stack's frame origin for each: two drift phases (wall-time override ~90 min apart ⇒ different X offset) and one dimmed state (grace overridden to fire immediately) — geometry deltas must match the zigzag math and alphas must show 0.5/hidden-hint.
- Test seams: `ShieldContentView` takes optional `referenceMinutes`/`dimImmediately` init parameters used only by the snapshot runner (production callers pass nothing).
- The on-hardware eyeball ([ticket 03](issues/03-verify-on-oled.md)) and releases ([05](issues/05-ship-stage-1.md)/[06](issues/06-ship-stage-2.md)) stay HITL.
