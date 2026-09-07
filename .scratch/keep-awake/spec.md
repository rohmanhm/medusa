# Spec: Keep Awake sessions

Status: ready-for-agent
Sources: [map](map.md) charting decisions 1–15 + research [01-power-assertions](research/01-power-assertions.md) / [02-amphetamine-audit](research/02-amphetamine-audit.md) / [03-session-mechanics](research/03-session-mechanics.md) / [04-process-detection](research/04-process-detection.md) + [05 answer](issues/05-while-running-in-v1.md). Where this spec and the research disagree, the research (with citations) wins.

## Problem Statement

The user steps away from a Mac that is still working — an agent run, a build, a render, a training job — and the Mac idles into sleep, pausing the work. Today's Medusa only keeps the machine awake while its input shield (Lock) is up, as a boolean tied to one toggle. There is no way to say "keep this Mac awake for the next 2 hours / until 5 PM / indefinitely" without locking input, no countdown, no battery safety, and no honest explanation when a deadline passes during forced sleep. Amphetamine proves the shape users expect, but Medusa's audience needs it composed with the Lock instead of colliding with it.

## Solution

Keep Awake becomes a first-class peer of the Lock: from the menu bar (or a hotkey, or at launch) the user starts a keep-awake Session — indefinitely, for a duration, or until a clock time — at Display awake or System awake level, from editable Presets. One engine holds the OS assertion while any Hold is live (user Sessions plus the Lock hold the Lock places while engaged). Deadlines are absolute end times. A Battery guard ends Sessions on low battery with a notification. End-of-session notifications explain un-chosen ends and offer Extend. Everything is customizable from a dedicated Keep Awake settings surface. "While an app/process is running" is deferred to the first follow-up (see ticket 05 answer) — v1 ships three End conditions.

## User Stories

1. As a user with a long agent run, I want to start an indefinite Session from the menu, so that the Mac stays awake until I stop it.
2. As a user starting a 2-hour render, I want a one-click 2 h Preset, so that I don't fiddle with a picker.
3. As a user with an overnight job, I want a 12 h Preset and Custom durations, so that the Session covers the whole run.
4. As a user who wants the screen dark but the job alive, I want a System awake level, so that the display may sleep while compute continues.
5. As a user presenting output, I want Display awake (the default), so that the screen stays lit.
6. As a user who locks mid-Session, I want the Lock to add its own Lock hold, so that unlocking doesn't silently kill my Session and locking doesn't silently extend it.
7. As a user whose Session ends while locked, I want nothing visible to change until unlock, so that the shield never flickers because a background timer fired.
8. As a user who locks without any Session, I want today's behavior byte-for-byte (Keep Awake toggle, forced hold for auto-locks, one failure alert per lock, reaffirm on wake), so that the engine migration never regresses the Lock.
9. As a forgetful user, I want Quick start (right/⌃-click the status item) to toggle a Session with the Default duration, so that keep-awake is one gesture with no menu.
10. As a keyboard-driven user, I want a second recordable hotkey that toggles a Session with the Default duration, so that I never touch the menu.
11. As a user with sacred app chords, I want that hotkey unassigned by default, so that Medusa never steals a chord on install.
12. As a user ending at a wall-clock time, I want Until… (clock-time picker), so that "awake until 5:00 PM" is exact.
13. As a user with an odd duration, I want Custom… (hours/minutes), so that presets never box me in.
14. As a user watching the menu, I want an active header (`Awake · 1 h 23 m left` / `· indefinitely` / `· until 5:00 PM`, plus `also: lock` when the Lock hold is live), so that nothing about why the Mac is awake is hidden.
15. As a user extending a running Session, I want Extend (+15 min / +30 min / +1 h) from the menu and from the ending-soon notification, so that I never stop-and-restart to buy time.
16. As a user stopping early, I want Stop Keep Awake, so that the Mac returns to its normal schedule immediately with no notification nag.
17. As a user who started a Session by hand and stopped it by hand, I want no notification either time, so that deliberate actions stay quiet (the icon already changed).
18. As a user whose Session ended without my hand (elapsed, end time passed, battery guard), I want a "Keep Awake ended — <reason>. Your Mac will sleep on its normal schedule." notification, so that I know why the Mac may now sleep.
19. As a hands-off watcher, I want an opt-in "Ending in 5 minutes" nudge with Extend, so that I can save a Session I'm watching output from (default off: if I'm touching the Mac it isn't idle, if I'm away I won't see it).
20. As a laptop user, I want the Battery guard (default on) to end Sessions on battery at ≤ threshold or OS Final warning, so that an unattended Mac sleeps instead of dying.
21. As a user on AC, I want the guard to never fire, so that plugged-in Sessions run to their deadline.
22. As a user who denies notification permission, I want the menu Extend path to keep working with one latched explanation, so that denial never strands a Session.
23. As a user who quits Medusa, I want every Hold to end silently with no confirmation dialog, so that quit always means quit.
24. As a user who enables start-at-launch, I want a Session with the Default duration at launch, so that an always-on Mac resumes its promise after reboot.
25. As a user who closes the lid mid-Session, I want the deadline (not a stopwatch) to rule on wake — passed → end + notify, otherwise reaffirm — with copy that says the end time passed while the Mac slept, so that lost sleep time is never silently added back.
26. As a user editing preferences, I want editable Presets, Default duration (default Indefinitely), default Awake level, guard on/off + threshold, notification toggles + lead time, hotkey, countdown toggle, and start-at-launch in one Keep Awake tab (with "Keep Mac awake while locked" moved there), so that every behavior in this spec has one knob.
27. As a user glancing at the menu bar, I want an optional countdown (`1:23`) beside the icon that ticks on minute boundaries without width jitter, so that remaining time is ambient.
28. As a status-item user, I want the icon to reflect idle / awake / locked, so that state is readable at a glance.
29. As a preempt user, I want idle auto-lock to still shield input during a Session (not paused), with the auto-lock forcing keep-awake exactly as today, so that stepping away stays safe.
30. As a lock-only user with no Sessions, I want zero new prompts (no notification permission request until the first Session starts), so that v1 never nags users who didn't ask for it.
31. As a developer, I want a pure policy seam plus a script harness for all of the above, so that deadlines, level resolution, guard trips, and lock composition stay red/green without a GUI.
32. As a CLI user, I explicitly do NOT get "while process X runs" in v1 (deferred per ticket 05) — and I want no dead picker or half-matcher in the UI pretending otherwise.

## Implementation Decisions

### Vocabulary

Use CONTEXT.md terms exactly throughout code, copy, and tickets: Keep Awake · Hold · Session · Lock hold · End condition · Awake level · Preset · Default duration · Quick start · Battery guard. The v1 End conditions are: indefinitely, for a duration, until a clock time.

### Seam

One seam: a pure decision surface (KeepAwakePolicy) covering start / extend / stop, deadline-passed-on-wake, Battery guard trip, Awake-level resolution across Holds (strongest wins), menu-header derivation, hotkey-while-locked → ignore, and Lock-hold composition. A script harness (`keep-awake-loop`) goes red/green over it headless, mirroring the LockPolicy + unlock-trap / preempt loop pattern. No other new seams; prefer existing ones (LockPolicy helpers, the power-assertion wrapper, settings facade, menu controller).

### Engine: one engine, many Holds

- A single owner (KeepAwakeController) holds the OS assertion while any Hold is live. Holds are user Sessions plus the Lock hold. Rejected: per-feature assertions (two sources of truth) and "lock adopts the session horizon" (silently ending a promise made via the lock toggle). Recorded as ADR-0001.
- The Lock stops owning the power assertion and instead places/withdraws a Lock hold on lock/unlock (including yield on system lock and release on system unlock). Lock-only behavior is preserved byte-for-byte: the Keep Awake toggle, preempt's forced hold for auto-locks, the once-per-lock keep-awake-failed alert, and reaffirm-on-wake.
- Sessions start only while unlocked (menu unreachable under the shield; the keep-awake hotkey is ignored while locked). Locking during a Session adds the Lock hold; unlocking removes only it. A Session ending under Lock is a no-op while the Lock hold stands. Preempt idle auto-lock is not paused by a Session.
- No persistence: a Session dies with the process; quit ends every Hold with no dialog.

### Awake levels

- Display awake (default): screen lit + system running. System awake: screen may sleep, system keeps running. Strongest live level wins. The Lock hold is always Display awake (the shield must be visible).
- OS mapping (research 01, Amphetamine precedent): Display awake holds `PreventUserIdleDisplaySleep` plus `PreventUserIdleSystemSleep` alongside (self-documenting in `pmset`); System awake holds the latter alone. `PreventSystemSleep` is never used. Neither level survives lid close, low battery, or Apple menu → Sleep — copy stays honest about that.

### Power assertion mechanics

- The assertion wrapper becomes level-aware with two assertion IDs, created with timeout properties so the kernel disarms a hung app at the deadline; Extend re-arms the timeout on the same ID. Foundation `beginActivity` is rejected (same assertions underneath, no timeout, no handle, teardown to change level).
- Gotcha (research 01, verified live): after a timeout turn-off the assertion object still reports level On — `held` is tracked from the deadline, never from the object. The harness keys on pid in `pmset` output and never calls the streaming assertions log.

### Deadlines, not stopwatches (hardcoded)

- A duration becomes an absolute end time at start. The ≤ 1 s self-correcting tick that re-reads the wall clock is the sole authority, re-evaluated on wake and on system-clock change (timers stop during sleep; wall-deadline scheduling is a hint, not a wake guarantee). The kernel timeout is re-derived from `deadline − now` on every wake/Extend as a fail-safe outer bound only.
- No "timer vs system clock" preference (Amphetamine has one; Medusa hardcodes deadline as simpler and honest). The ended-notification copy answers the stopwatch complaint: `End time (4:00 PM) passed while your Mac slept`.
- Precision target ±2 s; above-60 s ticks align to the next minute boundary, ≤ 60 s ticks run at 1 s.

### Battery guard (Sessions only in v1)

- Default on (deliberate divergence — Amphetamine ships it off): while on battery, end Sessions when either charge ≤ threshold (default 10 %) or the OS battery warning level reads Final (~10 min real runtime), whichever lands first; fire the ended notification. On AC it never fires. Amphetamine's prompt-before-ending and restart-on-AC-reconnect stay out. Whether the guard should also cover the Lock hold is explicitly deferred (post-v1; touches shield copy).

### Notifications

- Never on start or manual Stop (Amphetamine deleted those in v4 — the icon already changes). "Keep Awake ended" fires only for un-chosen ends (duration elapsed, end time passed, battery guard) — default on — closing with `Your Mac will sleep on its normal schedule`, copy modelled on Amphetamine's reason strings. "Ending in 5 minutes" + Extend is a Medusa original — default off.
- Platform clauses (research 03): a bare bundle identifier is the whole requirement; delegate + categories register at launch, authorization is deferred to first Session start, `willPresent` is mandatory, no provisional authorization; touching the notification center without a bundle identifier traps uncatchably when unbundled — so the center is guarded by a bundle-id check as a codebase invariant, and every unbundled entry point (self-test, lock-test, snapshot runners) stays notification-free. Denial fallback: menu-only state + one latched explanation + greyed toggles. The menu Extend path is the guaranteed path (banner-vs-alert is the user's setting).
- Extend action on the notification (+30 min canonical, plus the menu's +15/+30/+60).

### Menu bar (one status item, no second icon)

Idle state:

```
🔒 Lock Now                    ⌘⇧L
Keep Awake ▸
    Indefinitely
    ──────────
    15 min   30 min   1 h   2 h
    4 h   8 h   12 h
    ──────────
    Until…   Custom…
    ──────────
    ✓ Display awake / System awake  (allow-display-sleep check row)
Settings…                      ⌘,
About
[Check for Updates…]
Quit
```

Active state (header disabled, then Extend/Stop):

```
Awake · 1 h 23 m left (+ also: lock when the Lock hold is live)
Awake · indefinitely / Awake · until 5:00 PM (variants)
Extend ▸   (+15 min / +30 min / +1 h)
Stop Keep Awake
…(rest as idle)
```

- Icon reflects idle / awake / locked (SF Symbols verified on the macOS 13 catalog; the 2024-only heat-waves cup is out). Optional countdown text beside the icon (Settings, default off) renders `1:23`/`0:59` and ticks on the minute boundary — format (not font) fixes jitter. Right/⌃-click = Quick start: toggle a Session with the Default duration without opening the menu (Amphetamine parity, zero new UI).

### Until… / Custom…

Presented as an alert with a date-picker accessory (the pattern the app already uses twice): Until = clock-time picker, Custom = hours/minutes. Picker-hosting menu-item views are rejected (run-loop-mode trap); popover polish is post-v1.

### Hotkey

Second recordable chord via the existing recorder, toggling a Session with the Default duration; default unassigned (this audience's chords are sacred); ignored while locked.

### Settings: new Keep Awake tab

- New tab alongside existing ones (fixed-size window idiom preserved), containing: Presets editor, Default duration (default Indefinitely), default Awake level, Battery guard on/off + threshold, notification toggles + lead time, hotkey recorder, countdown toggle, start-at-launch toggle, and the moved "Keep Mac awake while locked" toggle (out of Lock Screen). All keys join the settings facade + defaults registration with typed accessors; SwiftUI bindings idiom unchanged.
- Preference keys (names): keep-awake presets list, default duration, default level, guard enabled + threshold percent, ended-notification enabled, ending-soon enabled + lead minutes, keep-awake hotkey chord (keycode + modifiers + char + display), show-countdown, start-keep-awake-at-launch. Existing `keepAwake` key keeps its meaning (Lock hold) and moves UI homes only.
- Start-at-launch default off with default duration; no confirmation on quit.

### Presets

Default list: 15 min · 30 min · 1 h · 2 h · 4 h · 8 h · 12 h, editable (a Medusa original — Amphetamine's ladder is fixed; 12 h added for overnight). Default duration default Indefinitely (Amphetamine parity verbatim).

### "While running" (deferred, folded in per ticket 06§5)

Not in v1 — no picker, no matcher, no cap UI. The follow-up contract is recorded in ticket 05's answer (argv-substring matching, 30 s grace, mandatory 4 h cap, live match count) so the next effort starts decided.

### Compatibility invariants (must not regress)

- Sparkle stays inert while locked (existing four gates); Sessions never present update UI under the shield.
- Never-trap and the system-lock yield/release table are unchanged; Sessions add no new lock-exit path.
- Preempt forced keep-awake for auto-locks is preserved through the Hold migration.

## Testing Decisions

What makes a good test here: assert external behavior (did we hold the right level? end at the deadline? notify only un-chosen ends? survive wake correctly? compose with the Lock hold?) — never private timer ivars or tick counts.

- Pure policy harness: start/extend/stop derivation, deadline-passed-on-wake, guard trip (percent and Final-warning, AC vs battery), level max-wins across Holds, header-string derivation, hotkey-while-locked → ignore, lock-hold add/remove composition. Mirrors the LockPolicy + unlock-trap / preempt loop prior art: script exits 0/1, runnable headless.
- Existing self-test must still PASS; extend it to hold/release both Awake levels and prove via `pmset` output keyed on pid. Unbundled paths stay notification-free by the bundle-id guard (assert no trap under `swift run`).
- New CLI mode `--keepawake-test N` analogous to `--lock-test`: hold Display awake for N seconds, log assertion state, release cleanly; used by the verify ticket on hardware.
- HITL verify checklist (verify ticket): short-duration Session ends + notifies; Until/Custom pickers work; Extend from menu and from notification; guard trip on battery (or simulated path); lock-during-Session composition; Quick start right-click; countdown toggle; start-at-launch toggle; no permission prompt until first Session; lock-only behavior unchanged; `pmset` shows the right assertion per level.

## Out of Scope

- "While app/process is running" End condition (first follow-up; contract in ticket 05).
- Triggers of any kind (network, drive, display, power, schedule, audio, CPU, location) — Amphetamine's automation layer, a separate effort if ever.
- Closed-display / lid-closed mode, Drive Alive, file-download monitoring, screen-saver control, cursor jiggle.
- AppleScript / Shortcuts / URL-scheme automation; Session history / statistics; custom icon packs; sounds.
- End-of-session actions beyond notify (sleep / lock / shut down on end).
- Battery guard covering the Lock hold (post-v1 decision; touches shield copy).
- Shield showing Session state ("Awake until 5:00 PM") while locked (post-v1).
- Amphetamine sub-features already ruled out: prompt-before-guard, restart-on-AC, periodic reminders, timer-vs-clock preference, screen-saver control.
- Replacing `caffeinate` for terminal users; any security-boundary claim; CI pipeline; Homebrew cask changes beyond docs.

## Further Notes

- Implementation order: policy + harness → engine + assertion refactor + Lock-hold migration → menu → Keep Awake Settings tab → notifications → Battery guard → verify → README/docs → ship. Graduated into numbered tickets by the to-tickets step; ship tickets are HITL (this repo never auto-commits/pushes on main; releases need explicit approval).
- Version is decided at ship time: 0.3.0 (new peer feature) vs 0.2.x — default to 0.3.0; README Features rewrite ships with it.
- Where research contradicts charting, research wins — applied: notifications (bundle-id trap → invariant; no start/stop notifs; ending-soon default off), menu countdown format (`1:23`, minute-boundary), guard trip (percent OR Final), hotkey default (unassigned), Quick start (right-click), presets (editable original + 12 h), deadline hardcoded with sleep-honest copy, assertion (two IDs + timeout + Extend same-ID + held-from-deadline).
- Uncommitted OLED WIP in the shield/snapshot runner belongs to the OLED effort — this spec touches neither file.
