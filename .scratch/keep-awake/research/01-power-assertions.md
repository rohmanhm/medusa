# Research: Power assertions & battery facts for Keep Awake

Date: 2026-09-05
Effort: `.scratch/keep-awake/`
Question: What do macOS power assertions actually guarantee, can the kernel expire one on a deadline, and how does an accessory app read battery / power source cheaply? ([ticket](../issues/01-power-assertions.md), [map](../map.md) decisions 3–4, 6, 9, 15)

Every claim below is tagged **[H]** header (local SDK, path given), **[M]** man page, **[O]** observed on this machine 2026-09-05, **[D]** Apple docs, or **[I]** inference (reasoned, not proven).

Header paths are relative to
`$(xcrun --show-sdk-path)/System/Library/Frameworks/` — written below as `<SDK>/`.

## TL;DR

| CONTEXT.md Awake level | Assertion type(s) to hold | Properties | Notes |
|---|---|---|---|
| **Display awake** | `kIOPMAssertPreventUserIdleDisplaySleep` (`"PreventUserIdleDisplaySleep"`) — **plus** `kIOPMAssertPreventUserIdleSystemSleep` for legibility | `kIOPMAssertionNameKey` (required), `kIOPMAssertionDetailsKey`, `kIOPMAssertionTimeoutKey` = seconds to deadline, `kIOPMAssertionTimeoutActionKey` = `TimeoutActionTurnOff` | The display assertion **already** blocks idle system sleep [H]; the second one is belt-and-braces + shows intent in `pmset -g assertions`. Amphetamine does exactly this [O]. |
| **System awake** | `kIOPMAssertPreventUserIdleSystemSleep` (`"PreventUserIdleSystemSleep"`) only | same | Display is free to dim and sleep [H]; the Mac keeps computing. |
| ~~`PreventSystemSleep`~~ | **never** | — | `kIOPMAssertionTypePreventSystemSleep` is "Deprecated in 10.9. This assertion is not supported in any OS X releases." [H]. `caffeinate -s` uses it and it is AC-only [M]. Not for us. |
| ~~`NoDisplaySleepAssertion` / `NoIdleSleepAssertion`~~ | **never** | — | Deprecated in 10.7 legacy names for the two live types [H]. |

**Recommendation: IOKit `IOPMAssertionCreateWithProperties` + timeout, not `beginActivity`.** Foundation gives no timeout, no way to rename, and no handle to re-arm — see §3.

## 1. Awake levels → assertion types

### 1.1 Exact semantics (`<SDK>/IOKit.framework/Versions/A/Headers/pwr_mgt/IOPMLib.h`)

`kIOPMAssertPreventUserIdleSystemSleep` (line 292) — [H]
> "Prevents the system from sleeping automatically due to a lack of user activity. … **The display may dim and idle sleep** while `kIOPMAssertPreventUserIdleSystemSleep` is enabled, but the system may not idle sleep. **The system may still sleep for lid close, Apple menu, low battery, or other sleep reasons.** … This assertion has no effect if the system is in Dark Wake."

`kIOPMAssertPreventUserIdleDisplaySleep` (line 314) — [H]
> "Prevents the display from dimming automatically. … the display may still sleep for other reasons, like a user closing a portable's lid or the machine sleeping. If the display is already off, this assertion does not light up the display. … **While the display is prevented from dimming, the system cannot go into idle sleep.** This assertion has no effect if the system is in Dark Wake."

**The README claim is confirmed [H]:** the display assertion implies idle-system-sleep prevention. The mechanism is visible live — powerd holds its own assertion for it:
```
pid 533(powerd): [0x0003611f000199de] PreventUserIdleSystemSleep named: "Powerd - Prevent sleep while display is on"
```
[O, `pmset -g assertions`]

`caffeinate` maps 1:1 [M, `man caffeinate`]: `-d` = display assertion, `-i` = idle system sleep, `-m` = `PreventDiskIdle`, `-s` = the deprecated `PreventSystemSleep` ("valid only when system is running on AC power"), `-u` = `IOPMAssertionDeclareUserActivity` (5 s default). So `PowerAssertion.swift`'s "equivalent to `caffeinate -d`" comment is accurate.

### 1.2 Battery vs AC, lid closed, Low Power Mode, "Prevent automatic sleeping…"

- **On battery**: both idle assertions are still honored for *idle* sleep, but the header is explicit that low battery is a sleep reason the assertion does not cover [H]. Assertions are advisory: "IOKit power assertions are suggestions and OS X may not honor them under battery, thermal, or user circumstances" — stated for `kIOPMAssertNetworkClientActive` (line ~380) but the honest general reading [H/I].
- **Lid closed**: neither type prevents it [H, both blocks]. Consistent with the map's "closed-display mode is out of scope".
- **Low Power Mode**: no documented interaction with assertions anywhere in `IOPMLib.h` [H — searched, zero hits for `LowPower`/`OnBattery`/`AppliesToLimitedPower`]. Treat LPM as a *signal to the user*, not a thing that breaks the Hold [I]. (`kIOPMAssertionAppliesToLimitedPower` is **not** in the public SDK — private to powerd; do not use.)
- **"Prevent automatic sleeping when the display is off"** ([Apple Support](https://support.apple.com/guide/mac-help/set-sleep-and-wake-settings-mchle41a6ccd/mac)) sets the `pmset` `sleep` timer to 0 [I; `man pmset`: "sleep - system sleep timer (value in minutes, or 0 to disable)" [M]]. **It does not matter to us either way**: `PreventUserIdleSystemSleep` suppresses exactly the idle-sleep decision that timer drives [H/I]. With the checkbox **off** and System awake held, the Mac still does not idle-sleep.
- **Dark Wake**: neither assertion has any effect there [H]. Only reachable via Power Nap / scheduled wake — not a Session path.

### 1.3 Verdict for the vocabulary

- **Display awake** → `PreventUserIdleDisplaySleep` (+ `PreventUserIdleSystemSleep`). Screen lit, system computing. Today's Lock hold behaviour, unchanged.
- **System awake** → `PreventUserIdleSystemSleep`. Screen may sleep, system computing.
- Copy must not promise more: **no level survives lid close, low battery, or Apple menu → Sleep** [H].

## 2. Assertion timeout — and Extend

### 2.1 The keys (`IOPMLib.h` lines 784–840) [H]

- `kIOPMAssertionTimeoutKey` = `CFSTR("TimeoutSeconds")`: "specifies an outer bound, in seconds, that this assertion should be asserted. **If your application hangs, or is unable to complete its assertion task in a reasonable amount of time, specifying a timeout allows PM to disable your assertion so the system can resume normal activity.**"
- `kIOPMAssertionTimeoutActionKey` = `CFSTR("TimeoutAction")`; default is `TimeoutActionTurnOff`.
  - `kIOPMAssertionTimeoutActionLog` — logs only, assertion untouched.
  - `kIOPMAssertionTimeoutActionTurnOff` — logs, sets level to `kIOPMAssertionLevelOff`; **object survives**.
  - `kIOPMAssertionTimeoutActionRelease` — logs, releases the assertion; object gone.
- Re-arm: "The assertion may be re-armed by calling `IOPMAssertionSetProperty` and setting a new value for `kIOPMAssertionTimeoutKey`." [H]
- Timeout is only settable via `IOPMAssertionCreateWithProperties` or `IOPMAssertionCreateWithDescription` (which takes `Timeout` + `TimeoutAction` args, line 442) — **not** via today's `IOPMAssertionCreateWithName`.

### 2.2 Verified on this machine [O]

Probe: created `PreventUserIdleDisplaySleep` with `TimeoutSeconds = 6`, `TimeoutAction = TimeoutActionTurnOff`.

```
create rc=0 success=true id=42023
---- t=0 ----   pid 6932: PreventUserIdleDisplaySleep named: "MedusaProbe display"
                Timeout will fire in 6 secs Action=TimeoutActionTurnOff
---- t=8 ----   (assertion absent from pmset listing — kernel turned it off, app did nothing)
SetProperty(timeout=30) rc=0 success=true
---- after ---- pid 6932: PreventUserIdleDisplaySleep named: "MedusaProbe display"
                Timeout will fire in 30 secs Action=TimeoutActionTurnOff
```

So: **yes**, the kernel expires a "for 2 hours" Session even if Medusa hangs, and **yes**, `IOPMAssertionSetProperty(id, kIOPMAssertionTimeoutKey, newSeconds)` both re-arms an expired assertion and implements **Extend** on a live one — with the *same* `IOPMAssertionID` handle staying valid (pmset's displayed token changes, ours doesn't).

### 2.3 Gotchas

1. **`IOPMAssertionCopyProperties` lies after a TurnOff timeout** [O]: it still returned `AssertLevel = 255` (`kIOPMAssertionLevelOn`) at t=8 when `pmset` no longer listed the assertion. Do **not** use it to validate the engine's `held` flag. Trust the app's own deadline, or `pmset`/`IOPMCopyAssertionsByProcess`.
2. **Wall time vs awake time across system sleep is undocumented** [H — the header says only "an outer bound, in seconds"] and **unverified** here (would need a real sleep cycle). This is decision 6's territory: keep the **absolute end time** as the single authority and treat the timeout purely as a fail-safe, re-derived (`SetProperty`) from `deadline − now` on every wake and every Extend. Then the answer to the question stops mattering.
3. `IOPMAssertionSetProperty` returns `kIOReturnNotPriviliged` if another process created the assertion [H] — irrelevant for us, but it means a stale ID from a crashed run cannot be adopted.
4. Prefer `TimeoutActionTurnOff` over `TimeoutActionRelease`: TurnOff keeps the object so Extend can re-arm it. (`caffeinate` itself uses `TimeoutActionRelease` [O].)
5. Keep the timeout **longer than** the Session deadline (e.g. deadline + 60 s). The timeout must never be the thing that ends a Session the user is watching — Medusa's own timer ends it, and the notification (decision 10) fires from that.

## 3. Foundation `beginActivity` — same thing, less control

`<SDK>/Foundation.framework/Versions/C/Headers/NSProcessInfo.h` lines 88–182 [H]:
- `NSActivityIdleDisplaySleepDisabled = (1ULL << 40)` — "Used for activities that require the screen to stay powered on."
- `NSActivityIdleSystemSleepDisabled = (1ULL << 20)` — "Used for activities that require the computer to not idle sleep. This is included in `NSActivityUserInitiated`."
- "This API also provides a mechanism to disable system-wide idle sleep and display idle sleep… be sure not to forget to end activities that disable sleep." Activity ends automatically if the returned object deallocs.
- **"User preferences may override your application's request."**

**Same kernel assertions underneath — verified** [O]. `beginActivity(options: [.idleDisplaySleepDisabled, .idleSystemSleepDisabled], reason: "MedusaProbe foundation activity")` produced two IOKit assertions in `pmset -g assertions`, both named with the *reason* string:

```
pid 6932: PreventUserIdleSystemSleep  named: "MedusaProbe foundation activity"
pid 6932: PreventUserIdleDisplaySleep named: "MedusaProbe foundation activity"
```

**Choose IOKit.** Reasons, in order:
1. **No timeout.** Foundation exposes none — the whole belt-and-braces of decision 15 is unavailable, and there is no handle to `SetProperty` on. This alone decides it.
2. **No Extend.** Nothing to re-arm.
3. **Naming.** IOKit lets us set Name *and* Details *and* HumanReadableReason separately, so `pmset -g assertions` reads `Medusa — Keep Awake / Session until 5:00 PM`; Foundation gives one reason string for both assertions.
4. **Level control.** Withdrawing only the display half when the strongest live Hold drops to System awake is one `IOPMAssertionRelease`; with Foundation it is an end-and-rebegin.
5. `PowerAssertion.swift` already speaks IOKit. Zero migration.

The only thing Foundation adds is `NSActivitySuddenTerminationDisabled` / `AutomaticTerminationDisabled` — irrelevant for a foreground-ish accessory app.

## 4. Observability for the harness

`man pmset` [M]: "`-g assertions` displays a summary of power assertions… `-g assertionslog` shows a log of assertion creations and releases." (`assertionslog` **streams** — do not call it from a synchronous harness step.)

Observed format [O]:
```
Assertion status system-wide:
   PreventUserIdleDisplaySleep    1
   PreventUserIdleSystemSleep     1
Listed by owning process:
   pid 50381(Amphetamine): [0x0003613700019c16] 02:34:35 PreventUserIdleSystemSleep named: "Amphetamine (Single-Use - System)"
   pid 50381(Amphetamine): [0x0003613700059c17] 02:34:35 PreventUserIdleDisplaySleep named: "Amphetamine (Single-Use - Display)"
   pid 1705(caffeinate):   [0x000384e90001a3a0] 00:02:17 PreventUserIdleSystemSleep named: "caffeinate command-line tool"
	Details: caffeinate asserting for 300 secs
	Localized=THE CAFFEINATE TOOL IS PREVENTING SLEEP.
	Timeout will fire in 162 secs Action=TimeoutActionRelease
```

Harness recipe (repo pattern: `scripts/keep-awake-loop.swift`, exit 0/1):
- **Held at the right level**: `pmset -g assertions`, take the `Listed by owning process` block for our pid, assert the expected set of type strings. The owner name is the **running executable's** name [O — the probe showed `swift-frontend`, not the script], so key on **pid**, not name, when driving a `swift run` build; `scripts/build-app.sh` bundles give `Medusa Local`.
- **Released**: same call, assert our pid has no rows.
- **Timeout armed**: assert the `Timeout will fire in N secs Action=TimeoutActionTurnOff` line follows our row and `N` is within tolerance of `deadline − now`.
- **In-process** (`--self-test`): `IOPMCopyAssertionsByProcess(&dict)` returns `[CFNumber pid: [ {AssertType, AssertLevel, …} ]]` [H, line 710] — no shelling out. `IOPMCopyAssertionsStatus` gives the system-wide aggregate (max of all levels) [H, line 726]. Do **not** use `IOPMAssertionCopyProperties` for liveness (§2.3.1).
- Note `kIOPMAssertionLevelOn == 255`, not 1 [O].

## 5. Battery & power source recipe

Header: `<SDK>/IOKit.framework/Versions/A/Headers/ps/IOPowerSources.h` and `.../ps/IOPSKeys.h`. No entitlement, no sandbox exception, no privilege [H — none documented; verified from a plain SwiftPM binary [O]].

```swift
import IOKit.ps

struct PowerSnapshot {
    var onBattery: Bool          // IOPSGetProvidingPowerSourceType == kIOPMBatteryPowerKey
    var percent: Int?            // Current Capacity / Max Capacity * 100
    var lowPowerMode: Bool       // ProcessInfo.processInfo.isLowPowerModeEnabled
    var warning: IOPSLowBatteryWarningLevel
}

func snapshot() -> PowerSnapshot {
    let blob = IOPSCopyPowerSourcesInfo().takeRetainedValue()
    let providing = IOPSGetProvidingPowerSourceType(blob).takeRetainedValue() as String
    var percent: Int?
    for ps in (IOPSCopyPowerSourcesList(blob).takeRetainedValue() as Array) {
        guard let d = IOPSGetPowerSourceDescription(blob, ps)?.takeUnretainedValue() as? [String: Any],
              d[kIOPSTypeKey as String] as? String == kIOPSInternalBatteryType,
              let cur = d[kIOPSCurrentCapacityKey as String] as? Int,
              let max = d[kIOPSMaxCapacityKey as String] as? Int, max > 0 else { continue }
        percent = Int((Double(cur) / Double(max) * 100).rounded())
    }
    return PowerSnapshot(onBattery: providing == kIOPMBatteryPowerKey,
                         percent: percent,
                         lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
                         warning: IOPSGetBatteryWarningLevel())
}
```
Verified output on this Mac [O]: `providing: AC Power`, `type: InternalBattery … cur: 83 max: 100 charging: 0`, `IOPSGetTimeRemainingEstimate() = -2.0` (`kIOPSTimeRemainingUnlimited`), `IOPSGetBatteryWarningLevel() = 1` (`None`), `isLowPowerModeEnabled = false`.

Facts that shape the code:
- `IOPSGetProvidingPowerSourceType` returns one of `kIOPMACPowerKey` / `kIOPMBatteryPowerKey` / `kIOPMUPSPowerKey` [H].
- Apple power sources publish capacity **in percent** and `Max Capacity` is "usually 100%", but "the power source's software may specify the units" — so **always divide**, never read `Current Capacity` as a percentage [H, `IOPSKeys.h` lines 313–343].
- Copy semantics: `CFRelease` what `Copy…` returns; **do not** release `IOPSGetPowerSourceDescription`'s dictionary (`takeUnretainedValue`) [H].

**Notifications — use both, for different jobs** [H, `IOPowerSources.h`]:

| API / notify(3) name | Fires when | Use for |
|---|---|---|
| `IOPSCreateLimitedPowerNotification(cb, ctx)` (10.9+) / `kIOPSNotifyPowerSource` = `"com.apple.system.powersources.source"` | active source flips unlimited↔limited (AC↔battery/UPS) only | arming/disarming the Battery guard; cheapest — "your code will run less often and conserve battery life" |
| `IOPSNotificationCreateRunLoopSource(cb, ctx)` / `kIOPSNotifyTimeRemaining` = `"com.apple.system.powersources.timeremaining"` | percent or time-remaining changes — "fairly frequently while discharging or charging" | sampling the % against the guard threshold, only while on battery |
| `kIOPSNotifyLowBattery` = `"com.apple.system.powersources.lowbattery"` + `IOPSGetBatteryWarningLevel()` | macOS's own warnable level: `Early` ≈ ≤20 min, `Final` ≈ ≤10 min remaining | a *time*-based guard — see §7, decision 9 |
| avoid `kIOPSNotifyAnyPowerSource` | any attribute of any source | header explicitly says it "uses more energy to run your code" |

Both `CFRunLoopSourceRef` factories must be `CFRunLoopAddSource(CFRunLoopGetMain(), src, .defaultMode)` and the caller must release the source [H].

**Low Power Mode** — `<SDK>/Foundation.framework/…/NSProcessInfo.h` [H]:
- `ProcessInfo.processInfo.isLowPowerModeEnabled`, `API_AVAILABLE(macos(12.0))`. Repo targets macOS 13 → **no availability guard needed**.
- `NSProcessInfoPowerStateDidChangeNotification` (`ProcessInfo.processInfo` posts on `NotificationCenter.default`): "posted once any power usage mode of the system has changed. Once the notification is posted, use the `isLowPowerModeEnabled` property".
- Also there if wanted: `thermalState` + `NSProcessInfoThermalStateDidChangeNotification` (macOS 10.10.3+).

## 6. Sleep / wake

**Do assertions survive?** [H/I] An assertion is a userspace object owned by the process (`kIOPMAssertionRetainCountKey`, released when the owner dies [H]). It survives display sleep trivially — display sleep with a Display awake Hold *cannot happen from idle* in the first place. Across a **system** sleep the process survives, so the assertion object survives too; what can change underneath is (a) a timeout that fired [O], (b) forced sleep reasons the assertion never covered (lid, low battery, Apple menu) [H], (c) Dark Wake, where both types are inert [H]. That is exactly why `PowerAssertion.reaffirm()` exists, and it stays the right move.

**What to observe** (`<SDK>/AppKit.framework/Versions/C/Headers/NSWorkspace.h` lines 320–330 [H]) — all on `NSWorkspace.shared.notificationCenter`, **not** `NotificationCenter.default`:

| Notification | Meaning | Engine action |
|---|---|---|
| `NSWorkspace.didWakeNotification` | system woke from full sleep | **re-evaluate every Hold's deadline**; passed → end Session + notify; else `reaffirm()` and re-arm the timeout from `deadline − now` |
| `NSWorkspace.willSleepNotification` | system about to sleep | nothing required; useful for logging why a Hold looked lost |
| `NSWorkspace.screensDidWakeNotification` (10.6+) | displays woke | cheap second chance to reaffirm; do **not** treat as a deadline event |
| `NSWorkspace.screensDidSleepNotification` (10.6+) | displays slept | if a Display awake Hold is live, this means something overrode us — worth surfacing |
| `NSWorkspace.sessionDidResignActive` / `…DidBecomeActive` | fast user switching | reaffirm on become-active (the existing lock code's precedent) |
| `NSWorkspace.willPowerOffNotification` | logout/shutdown | drop all Holds cleanly |

**IOKit root domain** (`IORegisterForSystemPower`, `IOPMLib.h` line 179 [H]) delivers `kIOMessageCanSystemSleep` / `kIOMessageSystemWillSleep` / `kIOMessageSystemWillPowerOn` / `kIOMessageSystemHasPoweredOn` and is the only way to *veto* an idle sleep (`IOCancelPowerChange` on `CanSystemSleep`; `WillSleep` is non-abortable and **must** be acknowledged with `IOAllowPowerChange` or the system stalls for ~30 s). **Do not use it.** Medusa's job is to hold an assertion, not to veto and certainly not to risk a stalled sleep. NSWorkspace covers everything the engine needs.

## 7. Impact on charting decisions

**Decision 4 (Awake levels) — confirmed, two refinements.**
The mapping stands exactly as charted. Refinements: (a) for **Display awake** hold *both* assertion types, not just the display one — Amphetamine does [O] and it makes `pmset -g assertions` self-documenting, at zero cost since the display type already implies system [H]; (b) the copy for both levels must not over-promise: **no** level survives lid close, low battery, or Apple menu → Sleep [H]. The "Prevent automatic sleeping when the display is off" checkbox is **irrelevant** to us and needs no Settings footnote.

**Decision 6 (Deadlines, not stopwatches) — reinforced, and now load-bearing.**
Whether the kernel's `TimeoutSeconds` counts sleep time is **undocumented and unverified**. Making the absolute end time the single authority — and re-deriving the assertion timeout from `deadline − now` on every wake and every Extend — makes the question moot. New constraint discovered: after a `TurnOff` timeout fires, `IOPMAssertionCopyProperties` still reports level `On` [O], so `PowerAssertion.held` cannot be validated against the assertion object. The engine's own clock is the truth.

**Decision 9 (Battery guard) — should change: add a time-based trip.**
A 10 % threshold is fine but arbitrary; macOS already publishes its own warnable levels via `IOPSGetBatteryWarningLevel()` — `Early` ≈ ≤20 min, `Final` ≈ ≤10 min of runtime [H], with `kIOPSNotifyLowBattery` to wake on. **Recommendation:** trip the guard on `percent ≤ threshold` **OR** `IOPSGetBatteryWarningLevel() == kIOPSLowBatteryWarningFinal`, whichever comes first. A 10 %-on-a-tired-battery Mac can have four minutes left; `Final` catches that. Cheap (one enum read), no new UI, and the guard becomes honest on old hardware. Wiring: arm on `IOPSCreateLimitedPowerNotification`, sample on `IOPSNotificationCreateRunLoopSource` **only while on battery**.

**Decision 15 (Architecture) — confirmed, one shape change.**
IOKit-with-timeout is the right call and **Extend is verified implementable** with `IOPMAssertionSetProperty(id, kIOPMAssertionTimeoutKey as CFString, seconds as CFNumber)` [O]. Shape change: `PowerAssertion` should grow **two assertion IDs (one per type), not one ID plus a level** — Display awake holds both, System awake holds one, and dropping from Display to System is a single `IOPMAssertionRelease` of the display half rather than a tear-down. Creation must move from `IOPMAssertionCreateWithName` to `IOPMAssertionCreateWithProperties` (the only public way to set a timeout on creation, alongside `IOPMAssertionCreateWithDescription`).

**Decision 3 (One engine, many Holds) — no change.** One engine owning one-or-two IOKit objects is still one source of truth.

## 8. Sources

- `<SDK>/IOKit.framework/Versions/A/Headers/pwr_mgt/IOPMLib.h` — assertion types (275–380), `IOPMAssertionCreateWithDescription` (442), `IOPMAssertionCreateWithProperties` (496–537), `IOPMAssertionSetProperty` (678–690), `IOPMCopyAssertionsByProcess` (694–710), `IOPMCopyAssertionsStatus` (714–726), timeout keys (784–840), deprecated types (999–1037), `IORegisterForSystemPower` (127–223).
- `<SDK>/IOKit.framework/Versions/A/Headers/ps/IOPowerSources.h` (whole file, 379 lines) and `.../ps/IOPSKeys.h` (capacity 300–343, state 311, type 511/740, values 762/768).
- `<SDK>/IOKit.framework/Versions/A/Headers/IOMessage.h` — `kIOMessageCanSystemSleep` / `SystemWillSleep` / `SystemWillPowerOn` / `SystemHasPoweredOn` (131–175).
- `<SDK>/Foundation.framework/Versions/C/Headers/NSProcessInfo.h` — `NSActivityOptions` (88–182), `isLowPowerModeEnabled` (222), `NSProcessInfoPowerStateDidChangeNotification` (236–242).
- `<SDK>/AppKit.framework/Versions/C/Headers/NSWorkspace.h` — sleep/wake/session notifications (320–330).
- `man caffeinate` (Darwin, 2012-11-09); `man pmset` (`-g assertions`, `-g assertionslog`, `sleep`/`displaysleep` timers).
- Apple Support, ["Set sleep and wake settings for your Mac"](https://support.apple.com/guide/mac-help/set-sleep-and-wake-settings-mchle41a6ccd/mac).
- Local probes 2026-09-05: `pmset -g assertions`, `pmset -g custom`, a Swift assertion-timeout/`SetProperty`/`beginActivity` probe, and a Swift `IOPS*` probe. Scripts in the session scratchpad; both are ~30-line throwaways, reproducible from §2.2 and §5.
- In-repo: `Sources/Medusa/PowerAssertion.swift`, `CONTEXT.md`, [`map.md`](../map.md).

## Verdict for the spec

Keep IOKit. Move to `IOPMAssertionCreateWithProperties`; hold **two** assertion IDs so Display awake and System awake are distinct, legible objects; always set `TimeoutSeconds = deadline − now + 60` with `TimeoutActionTurnOff`; re-arm with `IOPMAssertionSetProperty` on Extend and on every wake. The engine's absolute deadline is the only clock that ends a Session — the kernel timeout is the thing that saves the user when Medusa is the one that's broken. Battery guard trips on percent-or-`Final`-warning; power-source changes arrive on `IOPSCreateLimitedPowerNotification`, deadlines get re-checked on `NSWorkspace.didWakeNotification`, and Medusa never registers a sleep veto.
