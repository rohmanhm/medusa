# Medusa

Medusa is a macOS menu-bar utility for stepping away from a Mac that is still working: it shields input behind an authenticated lock and keeps the machine awake while long-running work finishes.

## Language

### Locking

**Lock**:
The state in which Medusa swallows keyboard input and covers every display with a Shield until the user authenticates.
_Avoid_: screen lock, freeze, lockdown

**Shield**:
The full-screen black window Medusa draws on each display while locked; clicks land on it harmlessly.
_Avoid_: overlay, curtain

**Backstop**:
The absolute horizon after which a Lock releases itself no matter what else has failed.
_Avoid_: dead-man's switch, fail-safe timer

**Fail open**:
Releasing, or refusing to raise, a Lock when Medusa cannot truly block input or present authentication.

**Never-trap**:
The invariant that no unlock path may leave force-shutdown as the only way out of a Lock.

**System lock**:
macOS's own lock screen (loginwindow). Medusa yields to it and releases on system unlock.
_Avoid_: OS lock, native lock, login screen

**Yield**:
Getting entirely out of the System lock's way while remaining notionally locked so a later system unlock still releases Medusa.

**Preempt**:
Opt-in behavior where idle time or ⌃⌘Q engages a Lock before the System lock would.
_Avoid_: auto-lock, lock-screen replacement

**Race loss**:
The System lock appearing before a Preempt could engage Medusa.

### Keeping awake

**Keep Awake**:
The feature that stops the Mac from idling into sleep, with or without a Lock.
_Avoid_: caffeinate, amphetamine, stay awake, anti-sleep

**Hold**:
One live reason the Mac is being kept awake. The Mac stays awake while at least one Hold exists.
_Avoid_: assertion, lease, demand

**Session**:
A Hold the user starts deliberately, carrying an End condition and an Awake level.
_Avoid_: timer, countdown, caffeinate run

**Lock hold**:
The Hold a Lock places while engaged: by the user's setting for manual locks, always for a Preempt lock.

**End condition**:
What terminates a Session: indefinitely, for a duration, or until a clock time.
_Avoid_: mode, trigger

**Awake level**:
How much of the Mac a Hold keeps on. **Display awake** keeps the screen lit and the system running; **System awake** lets the screen sleep but keeps the system running. The strongest level among live Holds wins.
_Avoid_: sleep prevention type

**Preset**:
A user-editable duration offered for one-click Session start.

**Default duration**:
The End condition used when a Session starts without one being chosen: by Quick start, the hotkey, or start-at-launch.

**Quick start**:
Starting (or stopping) a Session with the Default duration from a single gesture, without opening the menu.

**Battery guard**:
Ending Sessions when the battery drops below a threshold while unplugged.
_Avoid_: low-battery cutoff
