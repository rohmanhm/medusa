# Research: Preempt idle + ⌃⌘Q without replacing loginwindow

Date: 2026-07-24  
Effort: `.scratch/system-lock-preempt/`  
Question: How can a menu-bar app detect **idle** and **⌃⌘Q** and engage Medusa **before** the stock path hands the session to loginwindow / display sleep — without modifying loginwindow?

## TL;DR

| Trigger | Mechanism | Reliability | Recommendation |
|---|---|---|---|
| **Idle** | Poll `CGEventSource.secondsSinceLastEventType(.hidSystemState, kCGAnyInputEventType)` against a configured threshold; on fire call Medusa `lock()` with **keep-awake forced**. Once the power assertion is held, display-idle sleep (and therefore the usual “require password after display sleeps” lock) is starved. | High — public CoreGraphics API, no special entitlement, verified on this machine. | **Ship as the primary promise.** |
| **⌃⌘Q** | Always-on (when setting on) **consuming** session event tap (or dedicated keyDown path) that matches Control+Command+Q (keyCode 12) and swallows the event, then calls Medusa `lock()`. | **Best-effort.** v1 research already flags ⌃⌘Q as partly reserved / handled by loginwindow at high priority; session taps cannot be assumed to fully suppress it. | **Ship as secondary best-effort**; if the chord still reaches the system, fall through to the existing system-lock observers (release on unlock, never re-trap). |
| **Power button / lid** | No public pre-lock intercept (firmware / SMC). We only see `com.apple.screenIsLocked` after the fact. | N/A for preempt. | **Out of product promise.** Keep never-trap release on system unlock. |
| **loginwindow UI swap** | Not available to a normal session app. | — | **Forbidden.** |

## 1. Idle detection (primary)

### API

```swift
import CoreGraphics

func systemIdleSeconds() -> CFTimeInterval {
    CGEventSource.secondsSinceLastEventType(
        .hidSystemState,
        eventType: CGEventType(rawValue: ~0)! // kCGAnyInputEventType
    )
}
```

- Prefer **`.hidSystemState`** so synthetic / app-posted events don’t reset idle.
- No Accessibility grant required just to *read* idle time (probe on this machine returned live values).
- Poll on a short timer (e.g. 1–5 s) while the setting is on and Medusa is **unlocked**. Stop the timer while locked (Medusa already owns the session).

### Threshold

macOS does not publish a single “seconds until lock screen” number that matches every Energy / Lock Screen configuration. Practical options:

1. **Medusa-owned threshold** (picker: 1 / 2 / 5 / 10 / 15 min, default 5) — honest, controllable, no private Screen Time / powerd APIs.
2. Attempt to mirror `pmset` display sleep + screensaver `idleTime` — fragile across battery/AC, power modes, and “require password after …” grace.

**Decision for this effort:** Medusa-owned threshold with a clear Settings label (“Engage Medusa after … of idle”). Footer explains this is Medusa’s timer, not a rewrite of System Settings Energy. Once Medusa locks with keep-awake, system display-idle sleep is blocked by the existing assertion (`PreventUserIdleDisplaySleep` — see v1 research / `PowerAssertion.swift`).

### Race with system display sleep

If the user’s system display-sleep is **shorter** than Medusa’s idle threshold, loginwindow can still win first. Mitigations in product copy + implementation:

- Default Medusa idle (5 min) is a reasonable starting point; footer warns to set Medusa’s idle **≤** system display sleep if they want Medusa first.
- On `com.apple.screenIsLocked` while **unlocked** and setting on: we **lost the race**. Fire the **one-time warning** (charting decision B), do **not** try to cover loginwindow.

## 2. ⌃⌘Q intercept (secondary, best-effort)

### Facts

- Chord: Control + Command + Q, ANSI keyCode **12**.
- Current `HotKey` uses `NSEvent.addGlobalMonitorForEvents` which **observes without consuming** — cannot stop the system lock.
- A **session** `CGEventTap` with `.defaultTap` + head-insert **can** swallow many keyDowns when Accessibility is granted (Medusa already has this consent for the lock-time input tap).
- v1 research (`01-input-interception.md` §3.4) lists **`⌃⌘Q` lock screen partly** among combos that are “pre-OS or handled by `loginwindow` at high priority; not tappable” in the strong sense. Treat full suppression as **unreliable across OS versions**.

### Implementation shape

- Small dedicated **preempt monitor** (not the lock-time InputTap): installed only while the setting is on and Medusa is unlocked.
- Mask: keyDown (+ flagsChanged if needed for chord edge cases).
- On match: return `nil` (swallow) **and** call the auto-lock path.
- If Accessibility is missing: cannot install; surface via existing permissions path; setting remains on but ineffective until grants return (same as lock).

### Failure

If the system still locks: existing `screenIsLocked` / `screenIsUnlocked` observers apply. Never re-front Medusa over loginwindow; release Medusa if it was somehow still “locked” (today’s never-trap). Count as a race-loss for the one-time warning if we never engaged Medusa first.

## 3. What we must not do

- Draw over loginwindow / reaffirm shield while `systemScreenLocked` (unlock-trap regression).
- Call private `SACLockScreenImmediate` / login.framework lock helpers as a substitute for Medusa — out of scope and wrong product (that *is* the system lock).
- Claim security parity with the system lock screen.

## 4. Auto-lock keep-awake

Charting decision: auto-locks from this setting **force** the power assertion even if “Keep Mac awake while locked” is off. Implementation: `LockController.lock(forceKeepAwake: Bool = false)` (or a parallel `autoLock()` that sets a per-session flag). Manual hotkey / menu / lock-on-launch keep reading `AppSettings.keepAwake`.

## 5. One-time warning

When the setting is on and we detect a **system** lock without a preceding successful Medusa preempt (idle timer didn’t fire / chord wasn’t swallowed):

- Show **one** alert per setting-enablement lifetime (UserDefaults flag `systemLockPreemptWarned`), reset when the user toggles the setting off→on.
- Copy: Medusa couldn’t take over before macOS locked; raise Medusa’s idle threshold or lower system display sleep; ⌃⌘Q intercept is best-effort.

## 6. Sources

- Apple CoreGraphics: `CGEventSource.secondsSinceLastEventType` / `CGEventSourceStateID` / `kCGAnyInputEventType` (community + header convention `CGEventType(rawValue: ~0)`).
- Apple IOKit: `kIOPMAssertionTypePreventUserIdleDisplaySleep` (already in `PowerAssertion.swift`; v1 research `03-overlay-sleep.md`).
- In-repo: `.scratch/v1-spec/research/01-input-interception.md` (§3 reserved combos, including partial ⌃⌘Q); `.scratch/unlock-trap/spec.md` (never-trap session table).
- Local probe 2026-07-24: `CGEventSource.secondsSinceLastEventType` returns live idle seconds on the dev machine.

## Verdict for the spec

Ship **idle preempt + forced keep-awake** as the load-bearing feature; ship **⌃⌘Q swallow** as best-effort on the same toggle; never replace loginwindow; keep never-trap absolute; one warning on race loss.
