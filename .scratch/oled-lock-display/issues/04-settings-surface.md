# Stage 2: motion & dim controls in Settings

Type: task
Status: resolved
Blocked by: 02

> Goal-override execution (2026-07-21): built inline per [spec.md](../spec.md) §Stage 2 — motion picker (Subtle drift / Wander / Off) + dim-after picker with Never, one section, backstop-picker idiom.

## Question

Expose the stage-1 mechanism in Settings' lock-screen section — scope fixed at charting to **motion & dim only**:

- Motion style picker: the shipped style(s) plus **Off** (off restores today's static center).
- Dim-after-grace: toggle + timing, if dimming exists in the implementation (else add it here as an opt-in).
- Naming, control order, and defaults follow the existing `SettingsPanes.swift` patterns; keys join `AppSettings.Keys` + `registerDefaults()`; the shield keeps its read-once-per-lock contract.

The exact control set can't be finalized until [02](02-implement-safe-defaults.md) fixes which styles and parameters exist — that's why this is blocked, not fog. Check the map's *Not yet specified* for the preview-affordance question when this opens.

Done when: build + `--self-test` pass and the controls round-trip (change → next lock reflects it).

## Answer

Implemented 2026-07-21 (goal-override execution):

- **Screen Protection** section in `LockScreenPane`, between Message and Keep-awake: **Motion** picker (Subtle drift / Wander / Off → `shieldMotionStyle`) and **Dim after** picker (2/5/10/15/30 minutes/Never → `shieldDimMinutes`, Never = 0), one footer explaining the OLED why + "changes apply from the next lock". The Never-in-a-picker idiom mirrors the backstop picker. Pane and `SettingsWindowController.Tab.lockScreen` heights both 645 → 780.
- **Preview affordance** (map fog): ~~resolved as *not needed*~~ — superseded same day, see Comments.
- **Verified**: rendered via the new `--snapshot-lockpane` harness — section shows with registered defaults (Subtle drift / 10 minutes) proving the `@AppStorage` ↔ `registerDefaults` round-trip; runtime style/dim behavior for every style verified in [ticket 02](02-implement-safe-defaults.md) via the argument-domain overrides (`-shieldMotionStyle wander|off`).
- **Discovered en route**: `--snapshot-settings` was already broken before this effort — the toolbar-tab settings window throws (and swallows) an ObjC exception under headless launch on current macOS; identical hang on the untouched installed 0.2.1. The new `--snapshot-lockpane` path hosts the pane directly and sidesteps it. Fixing the full-window snapshot is out of this map's scope.

## Comments

**2026-07-21, preview decision reversed by the user** ("show the motion and dim demo in the preview"): `LockScreenPreview` now runs a sped-up demo instead of staying static — the honest speeds are invisible in a 150 pt box, so the preview compresses them: drift sweeps a preview-scaled zigzag box in 9/13-second periods, Wander relocates every 4 s with the real fade-teleport-fade choreography, and (when dim ≠ Never) a 12-second dim cycle shows the half-alpha state with the hint hidden and the fast recovery. A "Sped-up demo" caption marks the acceleration. Pure function of the wall clock over a half-second `TimelineView` — no timers, no state. Verified by two `--snapshot-lockpane` renders seconds apart catching the dimmed-and-offset phase and the bright centered phase respectively.
