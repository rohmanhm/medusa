# Gentle drift looked frozen / stuttered on lock

Type: bug
Status: resolved
Blocked by: 03

## Question

Field report (2026-07-22): with Screen Protection → **Gentle drift**, the lock
screen did not animate after lock no matter how long the user waited. Expected:
motion starts the moment the shield appears.

Follow-up (same day): motion was visible after Pass 2 but **stuttered** — not a
smooth glide. "I feel that it still stutter, not smooth when moving."

## Answer

Not a dead timer. Drift *was* running — but successive design mistakes made it
read as broken, then as stepped:

1. **Speed was still sub-perceptual.** Periods of 5/8 *minutes* over a 120×80 pt
   box ⇒ peak ~0.8 pt/s. Over 5 s the stack moved ~4 pt. A person staring at a
   full-screen clock cannot see that.
2. **Motion was 1 Hz snaps, not a glide.** `tick()` rewrote the target once a
   second and asked Auto Layout to animate the constraint change over 1.0 s.
   In practice the stack origin only changed on whole-second boundaries — no
   mid-second interpolation — so even the tiny motion looked like a stuck UI
   occasionally jittering.
3. **Triangular wave reverse = visible hitch.** Even with CVDisplayLink + layer
   transforms, the AOSP-style zigzag snaps velocity from +v to −v at every peak
   (Δv ≈ 2 × peak speed ≈ 50+ pt/s). The eye reads that as a kick every half-
   period, independent of frame timing.
4. **Off-main hop + coalesce.** `CVDisplayLink` callbacks arrive off main;
   hopping via `DispatchQueue.main.async` and dropping when a previous hop was
   still pending produces double-sized steps under main-queue load.
5. **`layout()` re-applied every Auto Layout pass.** The 1 Hz clock tick dirties
   labels → layout → `applyDrift()` mid-frame, fighting the display link once a
   second.
6. **Per-frame constraint pokes.** `setStackOffset` wrote `centerX/Y.constant = 0`
   every frame, dirtying Auto Layout at display rate for no reason.
7. **CADisplayLink started in `init` (no window).** A view-scoped link with no
   screen association is a silent no-op — the high-rate probe hung forever on
   that path until the driver was deferred to `viewDidMoveToWindow` and bound
   to `NSScreen`.

### Evidence (feedback loop)

Harness: `--motion-probe [seconds]` samples the real `ShieldContentView` stack
origin at display rate under forced drift.

**Before Pass 1 (red):**
```
frameSpan ≈ 3.8 pt over 5 s
distinct X positions = 6 (only jumps at t=1,2,3,4,5)
→ FAIL imperceptible / not smooth
```

**After Pass 2 (green on coarse probe, still stuttered to the eye):**
```
frameSpan ≈ 24.8–164 pt over 5 s
distinct X positions = 20 (every 0.25 s sample)
→ PASS on 0.25 s probe — but triangle reverse + main hop still hitch
```

**After Pass 3 (green on high-rate probe):**
```
samples=600 (119.8 Hz)
offsetSpan ≈ 45 pt / 5 s
step mean=0.076 max=0.106 pt
velocity kick max=0.56 pt/s
distinctX=600
→ PASS
```

Static geometry (`--snapshot-shield`) still matches the sine extremes under the
clamped amplitude (drift-a = center 0; drift-b = +X extreme, e.g. +701 on a
1728×1080 canvas).

### Fix

**Pass 1 (perceptible):** periods 45/73 s + 30 Hz Timer writing constraints.
User confirmed motion worked but called it "below 30 fps" and asked for full-area travel.

**Pass 2 (smooth-ish + full area):**
- **CVDisplayLink** drives apply at panel refresh (60/120 Hz), coalesced onto main.
- Position via **layer transform** (constraints stay centered) — no Auto Layout thrash.
- Travel box = **full usable screen** (view − stack − 24 pt pad), no 10%/120-pt cap.
- Periods scaled to **90 / 143 s** so peak speed stays calm across the larger box.
- Wander still first-relocates ~1.5 s after lock.

**Pass 3 (true glide — this change):**
- **Sine instead of triangle** — continuous velocity at turnarounds (periods
  140 / 221 s so peak speed stays ~calm across the full-screen box).
- **Main-thread `CADisplayLink`** bound to `window.screen` / `NSScreen.main`,
  started from `viewDidMoveToWindow` (not init). CVDisplayLink remains the
  macOS 13 fallback.
- **`layout()` only remeasures on real size change** — no mid-frame fight with
  the display link when the clock label ticks.
- **No per-frame constraint writes**; no-op transform writes skipped.
- **Cached `DateFormatter`s** + skip identical clock/date string writes.
- Settings preview: 60 Hz `TimelineView` + same sine, no ease-in-out between
  hops (that was the preview's own stutter).
- Probe: display-rate sampling + step/velocity-kick assertions + watchdog so a
  dead link can never hang the process again.

### Verify

```
.build/release/Medusa --motion-probe 5
# must PASS: ~60–120 Hz, maxStep ≪ 1 pt, velocity kick ≪ 25 pt/s
.build/release/Medusa --snapshot-shield /tmp/s
# drift-a offset ≈ (0, 0); drift-b X ≈ +(width/2 − stack/2 − 24)
.build/release/Medusa --self-test          # PASS
```

Restart the running app (old binary has the frozen / janky path):
`open "build/Medusa Local.app"` after quitting the previous instance.
