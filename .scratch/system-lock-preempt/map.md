# Map: System lock → Medusa

Labels: wayfinder:map

## Destination

A shipped Medusa release with an **opt-in setting**: when enabled, **idle** and **⌃⌘Q** engage Medusa's lock (shield + input block + keep-awake for those auto-locks) **instead of leaving the user on the stock path toward loginwindow / idle sleep** — without ever replacing or modifying loginwindow. Map closes when the setting is specified, built, verified, and released.

## Notes

- **GOAL OVERRIDE (2026-07-24)**: user directed `/to-spec` → `/to-tickets` → `/implement` and do not finish until verified. Loginwindow replacement is **explicitly forbidden** ("OS thing, too risky"). Commits/pushes/releases still require explicit approval (repo rule).
- **Execution lives in this map**: research → spec → tickets → implement → verify. Ship ticket stays HITL.
- **Charting decisions** (grilling 2026-07-24, locked before tickets):
  - Destination shape: **spec then ship** (one map).
  - Mechanism promise: **preempt**, never replace loginwindow.
  - Triggers (v1 product promise): **idle** + **⌃⌘Q**. Power button / lid are **not** promised.
  - Setting default: **off** (opt-in).
  - Preempt failure: **best effort + one warning** (no nag loop).
  - System unlock: **always release Medusa** — never-trap stays absolute (unlock-trap contract unchanged).
  - Keep-awake: **forced on for auto-locks only**; manual hotkey lock still follows the existing Keep Awake toggle.
- **Skills**: `/research` for mechanism facts; `/grilling` + `/domain-modeling` if a product decision reopens.
- **Tracker**: local markdown per `docs/agents/issue-tracker.md`. Research under `.scratch/system-lock-preempt/research/`.
- **Facts** (read before re-deriving):
  - Medusa is an **input shield**, not a security boundary (README + v1 research). loginwindow sits above anything a session app can draw; we must not fight it.
  - `LockController` already observes `com.apple.screenIsLocked` / `…Unlocked` and **releases on system unlock** (unlock-trap fix). Preempt must not reopen that trap.
  - `PowerAssertion` uses `PreventUserIdleDisplaySleep` (`caffeinate -d`) — once Medusa is locked with keep-awake, the system idle-lock path is starved of display-sleep.
  - Existing hotkey uses a **non-consuming** `NSEvent` global monitor — fine for ⌘⇧L, useless for swallowing ⌃⌘Q.
  - Session `CGEventTap` + Accessibility already required; a small always-on preempt tap can reuse that consent.
  - Prior research (`.scratch/v1-spec/research/01-input-interception.md`) flags ⌃⌘Q as **partly** reserved / not fully reliable to swallow — product must treat chord intercept as best-effort.
  - Idle is measurable publicly via `CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: kCGAnyInputEventType)`.

## Decisions so far

<!-- one line per closed ticket: gist + link -->

- Charting (no ticket) — destination, triggers, preempt, opt-in, one warning, never-trap absolute, keep-awake forced on auto-locks only, no loginwindow replacement.
- [Research: preempt mechanisms](research/01-preempt-mechanisms.md) — idle via `CGEventSource` is primary; ⌃⌘Q session-tap swallow is best-effort; never replace loginwindow; Medusa-owned idle picker.
- [Policy + harness](issues/01-policy-and-harness.md) — `LockPolicy` preempt helpers + `scripts/system-lock-preempt-loop.swift` (32 green).
- [Settings + monitor](issues/02-settings-and-monitor.md) — opt-in General toggle, idle picker, `SystemLockPreemptMonitor`, `lock(forceKeepAwake:)`, one race-loss alert.
- [Verify](issues/03-verify.md) — build + both harnesses + `--self-test` PASS on this machine.

## Not yet specified

- Ship version / release notes wording / notarized release (HITL — needs explicit commit + release approval).

## Out of scope

- **Replacing, theming, or injecting into loginwindow** — forbidden (user + OS risk).
- Power button / lid-close as a **guaranteed** trigger (may remain best-effort noise only).
- Default-on for all users.
- Re-trapping after system authentication (never-trap stays absolute).
- Claiming Medusa is a security boundary equivalent to the system lock screen.
- Private APIs / SIP tricks / AuthorizationExecuteWithPrivileges / login item helpers that wrap SACLockScreen*.
