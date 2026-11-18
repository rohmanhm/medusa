# Spec: Keep Awake Schedules

Status: ready-for-human
Decision record: [ADR-0002](../../docs/adr/0002-schedules-hold-by-the-clock.md)
Found by: [stability audit](../stability-audit/spec.md)

## Problem

Keep Awake has to be started by hand. The power log of the Mac this was built on shows what that costs. A Display awake Session was started every working morning for a week. When it ran out at 19:45 the display slept three minutes later with work still open. The indefinite Session started next was forgotten and kept three displays lit until 07:17 the next day.

## Solution

A Schedule is a weekly window: the days it starts on, a start time, an end time, and an Awake level. While the clock is inside an enabled window, Medusa holds the Mac awake at that level. Outside it the Mac sleeps on its normal schedule.

## Behavior

- A window belongs to the day it starts on. An end time at or before the start time runs into the next day. Equal times mean 24 hours.
- Several Schedules can overlap. The strongest Awake level among the open windows wins.
- A Schedule follows the clock. A launch, a wake, a time-zone change, or an edit inside the window takes effect within a second. A wake outside every window does nothing.
- The Schedule hold is a Hold on the one engine. It composes with a Session and with the Lock hold, and the menu header names every live Hold.
- **Pause Schedule Until <end>** in the menu lets the Mac sleep for the rest of the open window. **Resume Schedule** undoes it. The next window opens as usual. A pause does not survive a quit.
- The Battery guard keeps a Schedule off at the threshold and lets it back on when power returns. The menu says "Schedule waiting · battery low" meanwhile.
- A Schedule does not pause idle auto-lock. A Session does, because starting one is an explicit "I am here".
- No notifications. The status icon and the menu header show the state.

## Where it lives

- `KeepAwakeSchedule.swift`: the model, tolerant decoding from settings, and `SchedulePolicy` (which window is open, when the next one opens).
- `KeepAwakePolicy.swift`: `ScheduleStatus`, `scheduleStatus`, `tickPlan`, `kernelBound`, the menu copy.
- `KeepAwakeController.swift`: the Schedule hold, Pause and Resume, and the timer plan.
- `SchedulePane.swift`: the Settings tab and its copy.
- Stored as JSON under the `keepAwakeSchedules` defaults key.

## Out of scope

- Waking a sleeping Mac at a window's start. Idle assertions cannot do that, and `pmset schedule` needs root.
- Keeping the Mac awake with the lid closed.
- Other triggers (power adapter, Wi-Fi network, a running app).
- Dates, one-off windows, and holidays.

## Verification

- `swift test`: `SchedulePolicyTests` (windows, overnight, 24 hours, overlap, DST, decoding), `KeepAwakeEngineTests` (hold, release, Pause, Battery guard, composition, kernel timeout, the engine waking itself at a window's start, all read back through `pmset` where a kernel assertion is involved), `KeepAwakePolicyTests`, `ScheduleCopyTests`.
- `Medusa --schedule-test` on the debug binary and on the signed local bundle: `pmset` showed `PreventUserIdleDisplaySleep "Medusa keep awake (display)"` for the test pid. On the debug run the kernel timeout read 48218 seconds at 10:36, which is midnight plus 60 seconds.
- `Medusa --snapshot-schedulepane <dir>` renders the tab empty and with two Schedules.
- Not yet seen: the tab in the real Settings window, the menu items, and the app holding a Schedule across a real sleep and wake.
