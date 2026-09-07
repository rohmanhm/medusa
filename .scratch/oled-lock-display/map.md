# Map: OLED-safe lock display

Labels: wayfinder:map

## Destination

A shipped Medusa release where the lock display is **burn-in-safe by default for every user** — no static pixels held for hours — followed by a second shipped release adding a **motion & dim customization surface** in Settings. The map closes when both stages are released and the motion has been eyeballed on the dev machine's OLED.

## Notes

- **GOAL OVERRIDE (2026-07-21)**: the user directed spec → tickets → implement → verify in one push (`/goal`). The spec is [spec.md](spec.md); tickets 02/04 are executed inline by the agent; tickets 03 (OLED eyeball), 05 and 06 (releases) stay HITL — commits, pushes, and releases require explicit approval.
- **Execution lives in this map** (declared at charting, auto-updater precedent): implementation and ship tickets are in scope, not just decisions. Ship tickets stay HITL — commits, pushes, and releases require explicit approval (repo rule: never auto-commit/push).
- **Mechanism is delegated** (charting decision, 2026-07-21): the user chose not to pick drift vs pixel-shift vs dim by hand — [Burn-in mitigation research](issues/01-burn-in-research.md) surveys prior art and the agent decides from the findings. A HITL prototype ticket is the fallback only if research is inconclusive.
- **Charting decisions** (made while naming the destination, no tickets behind them):
  - Protection is **on by default for everyone** — no OLED panel detection (fragile, adds nothing; LCD users get an off switch in stage 2).
  - Stage-2 scope is **motion & dim controls only** (style picker incl. off, dim-after-grace toggle + timing). Everything else ruled out — see Out of scope.
  - **Two releases**: stage 1 ships on its own before stage 2 starts.
- **Skills**: `/research` for research tickets; `/grilling` + `/domain-modeling` if a decision ticket appears.
- **Tracker**: local markdown per `docs/agents/issue-tracker.md`. Research findings live under `.scratch/oled-lock-display/research/` (repo convention — no auto-commits, no research branches).
- **Facts** (read before re-deriving):
  - `Sources/Medusa/ShieldController.swift` — one `ShieldWindow` per screen, each with its own `ShieldContentView`; the clock/date/message/hint stack is **constraint-centered** (`centerX/centerY`, lines 133–136); motion must animate or replace those constraints (or transform the stack's layer). Shield is rebuilt on every lock and on screen changes; settings are read **once per lock**, so new prefs apply next lock — motion code inherits that contract.
  - A 1 s `Timer` already ticks the clock; the window sits at `CGShieldingWindowLevel()` (drops to screen-saver level during auth) — any animation must survive both levels.
  - `PowerAssertion` keeps the display lit while locked — burn-in exposure is hours-long by design; that's the whole reason this map exists.
  - Settings UI lives in `Sources/Medusa/SettingsPanes.swift` (SwiftUI, `@AppStorage` against `AppSettings.Keys`); stage-2 controls join the existing lock-screen section and defaults register in `AppSettings.registerDefaults()`.
  - Release pipeline from the auto-updater effort: `release.sh` + `scripts/update-appcast.sh`; DMG is the human download, zip is the Sparkle enclosure; publish order = release asset first, appcast push second (see [auto-updater ship ticket](../auto-updater/issues/06-ship-and-prove.md)).
  - `--snapshot-settings` (full window) hangs on current macOS — pre-existing, the toolbar-tab chrome throws under headless launch; use `--snapshot-lockpane` / `--snapshot-shield` instead. `docs/images/settings-lock-screen.png` is stale (no Screen Protection section) — refresh it during the stage-1 ship.

## Decisions so far

<!-- one line per closed ticket: gist + link -->

- [Burn-in mitigation research](issues/01-burn-in-research.md) — ship AOSP-style zigzag drift (minute-boundary steps, 83/521-min periods, 32×48 pt travel box, 1 s ease-in-out) **plus** dim-after-grace (10 min grace, alphas ×0.5 over 2 s, hint hidden, un-dim ≤0.15 s), both default-on; large-travel wander deferred to a stage-2 opt-in.
- [Implement burn-in-safe defaults](issues/02-implement-safe-defaults.md) — drift + dim live in `ShieldContentView` (wall-clock phase, per-screen clamped lockstep), un-dim/re-arm rides `setAuthMode`; verified via `--self-test` (PASS, 2 displays) and geometry-logging `--snapshot-shield` variants matching the zigzag model to <1 pt.
- [Stage 2: motion & dim controls in Settings](issues/04-settings-surface.md) — Screen Protection section (Motion: Subtle drift/Wander/Off; Dim after: 2–30 min/Never) in the Lock Screen pane, verified with the new `--snapshot-lockpane` harness; the preview runs a sped-up motion + dim demo (user reversed the initial "keep it static" call — see the ticket's Comments).
- [Eyeball on OLED](issues/03-verify-on-oled.md) — mechanism verified correct with real timers (dim fires on the grace boundary, drift steps on the minute); the "didn't work" report traced to drift being sub-perceptual by design + read-once-per-lock timing, not a bug. User accepted the feel and shipped without parameter changes.
- [Ship 05](issues/05-ship-stage-1.md)/[06](issues/06-ship-stage-2.md) — **released as v0.2.2** (2026-07-21). Both stages went out together (one interdependent changeset; user chose a patch bump over 0.3.0). Notarized zip+DMG, EdDSA-signed appcast live on `main`, tag at `290b14c`. **Destination reached.**
- [Long lock → macOS takeover](issues/07-long-lock-takeover.md) — field report of "motion/dim dead + shield gone + macOS lock" traced to **30m fail-safe auto-unlock**, not OLED math. Fix: default backstop **4h**, keep-awake failure alert, sleep/wake/session re-arm.
- [Gentle drift looked frozen / stuttered](issues/08-drift-imperceptible-on-lock.md) — Pass 1/2 made motion visible (CVDisplayLink + layer transform, full-screen box) but the eye still saw hitch: triangle-wave velocity reverse, off-main hop/coalesce, layout() re-apply on every clock tick, per-frame constraint pokes. **Pass 3:** sine path (140/221 s), main-thread `CADisplayLink` bound to `NSScreen` from `viewDidMoveToWindow`, layout only on real resize, no per-frame constraint writes. High-rate probe: 120 Hz, maxStep 0.11 pt, velocity kick 0.56 pt/s.

## Not yet specified

- ~~Whether the stage-1 default includes dimming or motion alone~~ — settled in [01-burn-in-research](issues/01-burn-in-research.md): dimming ships in the stage-1 default alongside drift (motion alone demonstrably insufficient per RTINGS; dimming is the strongest single lever, 2.8–4× slower wear at half luminance).
- ~~Whether stage 2 wants a preview affordance (see the motion without locking)~~ — settled in [04-settings-surface](issues/04-settings-surface.md), then reversed by the user same day: the preview now plays a sped-up demo of the selected motion and the dim cycle (ticket Comments have the details).

## Out of scope

- Clock format & size (12/24-hour, seconds, size presets) — the hardcoded `h:mm` stays; a 24-hour clock is a worthy *separate* effort.
- Static position choice (center/corner/edge placement when motion is off) — center stays the only static layout.
- Text opacity / brightness slider.
- OLED panel auto-detection — protection defaults on for everyone instead.
- Themes, wallpapers, screensaver-style visual content on the shield.
