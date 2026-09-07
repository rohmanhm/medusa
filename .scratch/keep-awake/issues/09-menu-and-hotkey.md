# 09 — Menu + hotkey + Quick start + countdown

**What to build:** the one-status-item menu (idle presets/Indefinitely/Until/Custom + level check; active header with also-lock + Extend/Stop), the second recordable hotkey (default unassigned, ignored while locked), right/⌃-click Quick start with the Default duration, idle/awake/locked icons, and the optional `1:23` minute-boundary countdown.

**Blocked by:** 08 — Engine + assertion refactor + Lock-hold migration

**Status:** resolved

- [x] Idle menu starts Sessions at the right level/deadline; active header/Extend/Stop reflect live Holds including the Lock hold
- [x] Quick start and hotkey toggle with Default duration; hotkey ignored while locked
- [x] Countdown shows `1:23` without width jitter, minute-boundary tick, toggle respected
- [x] Until…/Custom… pickers (alert + date-picker accessory) create correct Sessions

## Answer

Done 2026-09-07 (goal execution): `MenuBarController` rebuilt around one status item (idle: Indefinitely/presets/Until/Custom + allow-display-sleep check; active: disabled header with `also: lock`, Extend +15/+30/+60, Stop; locked: Sessions hidden) + left-click popup / right-ctrl-click Quick start + second `HotKey` (providers refactor, keep-awake chord default unassigned, ignored while locked) + idle/awake/locked icons + opt-in `1:23` countdown (writes only on change). Until = date-picker alert, Custom = hours/minutes alert. HITL eyeball of click feel + countdown toggle left to ticket 13/14.
