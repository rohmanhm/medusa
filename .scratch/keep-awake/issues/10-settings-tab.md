# 10 — Keep Awake Settings tab

**What to build:** the dedicated Keep Awake settings tab (editable Presets, Default duration default Indefinitely, default Awake level, guard on/off + threshold, notification toggles + lead, hotkey, countdown, start-at-launch) with "Keep Mac awake while locked" moved there from Lock Screen, all keys registered with typed accessors.

**Blocked by:** 08 — Engine + assertion refactor + Lock-hold migration

**Status:** resolved

- [x] Every behavior in the spec has one knob; defaults match spec (Indefinitely, Display, guard on@10 %, ended on, nudge off, hotkey unassigned, countdown off, launch off)
- [x] Presets edit round-trips into the menu; Default duration drives Quick start/hotkey/launch
- [x] Moved lock-toggle preserves meaning; single-pane snapshot runner verifies without hanging

## Answer

Done 2026-09-07 (goal execution): `KeepAwakePane` + `SettingsWindowController.Tab.keepAwake` (590x760, cup.and.saucer) with Sessions (editable comma presets, Default duration default Indefinitely, default level, start-at-launch), Battery guard, Notifications, Menu Bar & Shortcut (second recorder, countdown), and the moved "Keep Mac awake while locked" toggle; `LockScreenPane` slimmed (toggle moved, same key — meaning preserved). All keys in `AppSettings` + `registerDefaults` with spec defaults. Verified: `--snapshot-keepawakepane` renders every section; `--snapshot-lockpane` confirms the move.
