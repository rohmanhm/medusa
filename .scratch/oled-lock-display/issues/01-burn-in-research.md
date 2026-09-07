# Burn-in mitigation research: prior art → chosen mechanism

Type: research
Status: resolved

## Question

The lock display (clock 84pt thin @ 95% white, date, message, hint — constraint-centered on a black field, screen held awake for hours) must become burn-in-safe by default. The user delegated the mechanism choice: survey prior art, then **resolve this ticket with a recommended mechanism and concrete parameters**. Implementation ([02](02-implement-safe-defaults.md)) follows the recommendation directly.

Survey:

- **Pixel orbit / pixel shift** as shipped by OLED TV vendors (LG, Sony, Samsung): typical travel distance (px), interval, and pattern (orbit vs random), and how visible it is to a viewer.
- **iPhone StandBy** always-on night mode: how it relocates/dims the clock, on what cadence.
- **Apple Watch / iPhone always-on displays**: dimming levels and refresh strategy — how much does luminance reduction slow burn-in (burn-in is cumulative-luminance driven; quantify roughly if sources allow).
- **TV standby / screensaver clocks** (e.g. Apple TV, LG standby): full-screen slow drift patterns.
- Any macOS-specific prior art: what Amphetamine/lock-screen/screensaver utilities do about static overlays, if anything.

Deliver in the findings file:

1. A comparison of the candidate mechanisms (subtle pixel shift · full-screen slow drift · dim-after-grace · combinations) on protection strength, visibility, and implementation weight for an AppKit constraint-centered stack.
2. **A recommendation with numbers**: shift/drift interval, travel distance or wander region (as margin % of screen), animation duration/easing, and — if dimming is part of the default — grace period and dim level.
3. Whether the black background + thin-weight white text already mitigates enough that motion cadence can be relaxed.

Context: `Sources/Medusa/ShieldController.swift` (ShieldContentView), map Notes facts. Findings → `research/01-burn-in-mitigation.md`.

## Answer

**Ship subtle zigzag drift + dim-after-grace, both on by default** (full findings: [../research/01-burn-in-mitigation.md](../research/01-burn-in-mitigation.md)):

- **Drift** — AOSP-style triangular (zigzag) offsets on the stack's `centerX`/`centerY` constraint constants, recomputed **once per minute** on the minute boundary of the existing clock timer. Incommensurate periods **83 min (X) / 521 min (Y)** (AOSP `BurnInHelper.kt` constants — the path never visibly repeats); travel box **32 pt × 48 pt** (clamped to ≤5% of the smallest display dimension); per-minute steps ≈ **0.8 pt X / 0.2 pt Y**, each animated over **1.0 s ease-in-out** — sub-perceptual.
- **Dim-after-grace** — after **10 min** of lock-screen idle, multiply all label alphas by **0.5** over **2.0 s ease-out** (clock 0.95 → 0.475 etc.; ≈22–25% emitted luminance gamma-adjusted → ≥3× slower wear at n≈1.7) and **hide the hint line** (fully static, nonessential). **Un-dim in ≤0.15 s** on any input.
- **Not in the default:** large-travel wander (DeskClock-style relocation) — visible motion on a lock screen, violates HIG "consistent layout"; keep as a stage-2 opt-in mode (15-min relocation within central 60%, 3 s crossfade).

Rationale in one line: RTINGS proved pixel shift alone doesn't stop burn-in on bright long-lived static content while dimming attacks the wear driver itself (lifetime ∝ 1/L^n, n≈1.5–2) — the combination reproduces the full OLED-TV panel-care playbook (shift + static-area luminance reduction) at trivial AppKit cost. The existing black field + thin dim text already confines wear to the glyph pixels, but the colon/date/hint are static for hours, so motion cadence cannot be relaxed to nothing — the minute cadence above is already the relaxed form.
