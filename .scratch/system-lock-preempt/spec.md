# Spec: System lock → Medusa (preempt)

Status: ready-for-agent  
Sources: [map](map.md) charting decisions + [research/01-preempt-mechanisms.md](research/01-preempt-mechanisms.md). Where this spec and the research disagree, the research (with citations) wins.  
Hard constraint: **do not replace, theme, inject into, or fight loginwindow.**

## Problem Statement

When the user steps away, macOS may idle-lock or they may hit ⌃⌘Q out of habit. That path shows the stock lock screen and lets the machine sleep — long-running agents, builds, and renders pause, and Medusa’s input shield never engaged because they forgot the Medusa hotkey. They want an opt-in mode where “the Mac is about to lock” becomes a **Medusa lock** (shield + blocked input + stay awake) without pretending Medusa is the OS lock screen.

## Solution

An **opt-in** Settings toggle. While enabled and Medusa is unlocked:

1. **Idle preempt (primary):** after a configurable idle period with no HID input, Medusa locks itself and **forces keep-awake** for that lock session.
2. **⌃⌘Q preempt (best-effort):** when the chord is seen, Medusa tries to swallow it and lock itself the same way.
3. If macOS’s own lock still appears first, Medusa **does not cover loginwindow**. On system unlock Medusa **releases** if it was held (existing never-trap). The user gets **one** warning that preempt lost the race.

## User Stories

1. As a forgetful user, I want idle time to engage Medusa automatically, so my agents keep running under a shield without me pressing the hotkey.
2. As a user who muscle-memories ⌃⌘Q, I want that chord to prefer Medusa when I’ve opted in, so I don’t land on the stock lock by habit.
3. As a security-conscious user, I want this setting **off by default**, so Medusa never rewires system lock behavior until I choose it.
4. As a user, I want auto-locks from this setting to keep the Mac awake even if “Keep Mac awake while locked” is off, so the forgetfulness path still protects long work.
5. As a user, I want manual hotkey / menu locks to still honor the Keep Awake toggle, so power policy for deliberate locks stays mine.
6. As a user, I want a clear idle duration picker, so I can set Medusa to engage before my system display sleeps.
7. As a user, I want a one-time warning when macOS locked first, so I know the setting isn’t magic and can tighten idle timing.
8. As a user who authenticated at the system lock screen, I want Medusa to stay out of the way afterward, so I am never re-trapped (existing never-trap contract).
9. As a user without Accessibility grants, I want failed preempt install to route me to Permissions like a normal lock failure, so I’m not left thinking the feature is on when it can’t run.
10. As a user, I want turning the setting off to immediately stop idle polling and chord intercept, so behavior returns to stock Medusa instantly.
11. As a user already under a Medusa lock, I want idle polling paused, so we don’t stack locks or re-enter lock().
12. As a user who toggles the setting off and on again, I want the race-loss warning to be allowed once more, so a new attempt surface is honest.
13. As a user on multi-display, I want auto-lock to use the same full shield path as manual lock, so every screen is covered.
14. As a user, I never want Medusa to claim it replaced the macOS lock screen, so the security posture stays honest.
15. As a developer, I want pure policy + a script harness for preempt decisions, so never-trap and race-loss rules stay red/green without Touch ID.

## Implementation Decisions

### Settings surface

- New toggle in **Settings → General** (Startup / safety adjacency): **“Lock with Medusa when the Mac would idle-lock”** (final copy may shorten; must not say “replace lock screen”).
- Companion picker: **“Engage after”** — 1, 2, 5 (default), 10, 15 minutes of idle. Disabled visually when the toggle is off.
- Footer: explains idle is Medusa’s timer; set it ≤ system display sleep to win the race; ⌃⌘Q is best-effort; never a security boundary; does not modify macOS lock screen.
- Defaults: toggle **false**; idle minutes **5**; warned flag **false**.

### Preference keys

- `systemLockPreemptEnabled` (Bool, default false)
- `systemLockPreemptIdleMinutes` (Int, default 5)
- `systemLockPreemptWarned` (Bool, default false) — one-shot warning latch

Typed accessors on the existing settings facade; SwiftUI `@AppStorage` bindings in the General pane.

### Preempt monitor module

A dedicated monitor (name e.g. `SystemLockPreemptMonitor`) owned by the app delegate lifecycle:

- Starts when: setting on, permissions granted, Medusa unlocked.
- Stops when: setting off, or Medusa locked, or app teardown.
- **Idle:** Timer (~2 s) reads HID idle seconds via `CGEventSource.secondsSinceLastEventType(.hidSystemState, any-input)`. When idle ≥ threshold and still unlocked → request auto-lock.
- **⌃⌘Q:** Session event tap (keyDown, defaultTap, head-insert) matching Control+Command+Q (keyCode 12). Swallow (`nil`) and request auto-lock. If tap create fails → treat as permissions failure path (open Permissions), leave setting on.
- Reacts to UserDefaults changes live so toggling in Settings applies without relaunch.
- Must not run heavy work on the tap callback; hop to main for lock.

### Lock controller

- Extend lock entry with a parameter or dedicated method for **auto** locks: `forceKeepAwake: true` for this path only.
- Manual paths (hotkey, menu, lock-on-launch) keep `forceKeepAwake: false` and read the Keep Awake setting as today.
- No change to: release on `systemScreenDidUnlock`; ignore reaffirm while system screen locked; fail-open / backstop / wedge rules.

### Race-loss detection + warning

- App-level (or monitor-level) observation of `com.apple.screenIsLocked` while **unlocked** and setting **on** and we did **not** just initiate a Medusa lock → race lost.
- If `systemLockPreemptWarned` is false: show one alert (shield not up, so normal modal is fine), then set the flag true.
- Reset the flag when the user turns the setting from off → on.
- Do **not** call Medusa lock in response to system lock (that would fight loginwindow).

### Never-trap invariant

Unchanged decision table for session events while Medusa is locked. Preempt is only about **entering** Medusa lock earlier; exit rules stay:

- system unlock → release  
- system lock while Medusa locked → ignore (don’t re-front)  
- wake while system locked → ignore  
- wake otherwise → reaffirm  

### Copy / honesty

README or Settings must not say “override the macOS lock screen.” Prefer “engage Medusa before idle sleep” / “when the Mac would lock from idle.”

## Testing Decisions

Good tests assert **external behavior** (did we lock? keep-awake forced? release on system unlock? warning once?) not private timer ivars.

1. **Pure policy seam** (preferred, mirrors `LockPolicy` / `unlock-trap-loop.swift`):
   - Inputs: setting on/off, isLocked, idleSeconds vs threshold, chord seen, systemScreenDidLock while unlocked, forceKeepAwake intent.
   - Outputs: start/stop monitor, requestAutoLock, requestManualLock semantics, showWarning, session reaction still release-on-unlock.
2. **Script harness** `scripts/system-lock-preempt-loop.swift` (or extend unlock-trap-loop): red/green without GUI; exit 0/1.
3. **Existing** `--self-test` must still PASS (mechanical tap/shield/assertion).
4. **Manual / HITL** (verify ticket): enable setting, set short idle, confirm Medusa engages with keep-awake; cancel path still works; system unlock never re-traps; with setting on and ultra-short system display sleep, confirm one warning if system wins.

Prior art: `LockPolicy.swift`, `scripts/unlock-trap-loop.swift`, `SelfTest.swift`.

## Out of Scope

- Replacing or drawing over loginwindow.
- Guaranteed power-button / lid preempt.
- Default-on.
- Private login.framework lock APIs.
- Mirroring every System Settings Energy edge case.
- Security claims equivalent to FileVault / loginwindow.
- Ship/release automation without human approval.

## Further Notes

- Implementation order: policy + harness → settings keys/UI → monitor → wire AppDelegate/LockController → verify.
- If ⌃⌘Q swallow proves dead on a given OS version, idle preempt alone still ships the user’s stated goal (forgetfulness + keep-awake); chord remains best-effort in copy.
