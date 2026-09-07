# Power assertions & battery facts for Keep Awake

Type: research
Status: resolved
Blocked by: None — can start immediately

## Question

Medusa's Keep Awake engine ([map](../map.md), charting decisions 3–4, 6, 9, 15) needs hard facts about macOS power management before the spec can name APIs and defaults. Today `Sources/Medusa/PowerAssertion.swift` holds a single `kIOPMAssertionTypePreventUserIdleDisplaySleep` via `IOPMAssertionCreateWithName`. Establish, from primary sources (Apple's `IOPMLib.h` / IOKit docs, `man caffeinate`, `man pmset`, Foundation `ProcessInfo.beginActivity` docs, IOPowerSources headers):

1. **Awake levels → assertion types.** Exact semantics of `PreventUserIdleDisplaySleep`, `PreventUserIdleSystemSleep`, `PreventSystemSleep` (and `NoDisplaySleepAssertion`/legacy names): does the display assertion imply the system one (README claims yes — confirm)? What each does on battery vs AC, with the lid closed, in Low Power Mode, and under "Prevent automatic sleeping when the display is off" being off. Which pair implements **Display awake** and **System awake** as defined in `CONTEXT.md`.
2. **Assertion timeout.** `IOPMAssertionCreateWithProperties` with `kIOPMAssertionTimeoutKey` / `kIOPMAssertionTimeoutActionKey` (release / turn off / log): does it let the kernel expire a "for 2 hours" Session even if Medusa hangs? Can an existing assertion's timeout be updated via `IOPMAssertionSetProperty` (for **Extend**)? Any gotchas (timeout measured in wall time vs awake time — matters for charting decision 6).
3. **Foundation alternative.** `ProcessInfo.processInfo.beginActivity(options:)` with `.idleDisplaySleepDisabled` / `.idleSystemSleepDisabled` — same kernel assertions underneath? Reasons to prefer IOKit (names in `pmset -g assertions`, timeouts, level control) or Foundation.
4. **Observability for the harness.** How `pmset -g assertions` / `pmset -g assertionslog` report a process's assertions, so a verification step can prove the right level is held and released.
5. **Battery & power source.** `IOPSCopyPowerSourcesInfo` / `IOPSGetProvidingPowerSourceType` / `IOPSNotificationCreateRunLoopSource` (or `IOPSCreateLimitedPowerNotification`): how to learn "on battery" and "% remaining" and get notified on change, cheaply, from a non-sandboxed accessory app. Also `ProcessInfo.isLowPowerModeEnabled` + its notification.
6. **Sleep/wake.** Confirm assertions survive display sleep but not system sleep/lid close; which notifications (`NSWorkspace.didWakeNotification`, `screensDidWakeNotification`, IOKit root-domain) the engine should re-evaluate deadlines on.

Deliver in `../research/01-power-assertions.md`: a table mapping Display awake / System awake → assertion type(s) + properties; a recommendation on IOKit-with-timeout vs Foundation; the battery API recipe; and any fact that changes a charting decision (say which number). Cite every claim.

## Answer

Findings: [`../research/01-power-assertions.md`](../research/01-power-assertions.md)

1. **Levels.** Display awake = `kIOPMAssertPreventUserIdleDisplaySleep`, System awake = `kIOPMAssertPreventUserIdleSystemSleep`. The README claim is **confirmed by the header**: "While the display is prevented from dimming, the system cannot go into idle sleep." Still hold both types for Display awake — Amphetamine does, and it makes `pmset -g assertions` self-documenting. `PreventSystemSleep` and the `No*SleepAssertion` legacy names are deprecated; never use them. No level survives lid close, low battery, or Apple menu → Sleep, and both are inert in Dark Wake. The "Prevent automatic sleeping when the display is off" checkbox is irrelevant to us.
2. **Timeout — verified live.** `IOPMAssertionCreateWithProperties` + `TimeoutSeconds`/`TimeoutActionTurnOff` lets the kernel disarm a hung Medusa; `IOPMAssertionSetProperty(id, kIOPMAssertionTimeoutKey, n)` re-arms an expired assertion **and** implements Extend on a live one, same `IOPMAssertionID`. Gotcha: after a TurnOff timeout, `IOPMAssertionCopyProperties` still reports level On — `held` can't be validated from the assertion. Sleep-time accounting is undocumented, so the app's absolute deadline stays the authority.
3. **Foundation.** `beginActivity` creates the *same* two IOKit assertions (verified in `pmset`), but offers no timeout, no handle to re-arm, and one shared name. **Use IOKit.**
4. **Observability.** `pmset -g assertions` → key on **pid** (owner name is the executable's); `IOPMCopyAssertionsByProcess` in `--self-test`. `assertionslog` streams — don't call it synchronously.
5. **Battery.** `IOPSCopyPowerSourcesInfo` + `IOPSGetProvidingPowerSourceType` + `Current/Max Capacity` (always divide), armed by `IOPSCreateLimitedPowerNotification` and sampled by `IOPSNotificationCreateRunLoopSource` only while on battery. `ProcessInfo.isLowPowerModeEnabled` is macOS 12+ so no guard needed at our target.
6. **Sleep/wake.** Reaffirm and re-derive deadlines on `NSWorkspace.didWakeNotification` (on `NSWorkspace.shared.notificationCenter`); never register an `IORegisterForSystemPower` sleep veto.

**Decisions touched:** 4 confirmed (+ hold both types, honest copy); 6 reinforced and now load-bearing; **9 should change** — trip the Battery guard on `percent ≤ threshold` **OR** `IOPSGetBatteryWarningLevel() == kIOPSLowBatteryWarningFinal` (≈10 min left), since 10 % on a tired battery can be four minutes; 15 confirmed with a shape change — `PowerAssertion` holds **two assertion IDs**, not one ID plus a level. Decision 3 unchanged.
