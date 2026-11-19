# Watch a real unlock

Type: task
Status: ready-for-human

## Question

Do the two lock fixes (the Shield stays under the Touch ID dialog after a rebuild, a wake no longer cancels the dialog) hold on a locked screen with three displays, and are they what caused "the dialog sometimes needs the physical key"?

## Why a person is needed

The fixes are proven in `swift test` against the real `LockController` and real overlay windows, with the event tap and the Touch ID dialog replaced. A finger on the sensor and a dark display cannot be scripted, and the audit did not lock a Mac that was in use.

## Steps

Each command releases itself. Use the build under test, for example `build/Medusa Local.app`.

1. Run `Contents/MacOS/Medusa --self-test`. The displays go black for about a second. Expect `RESULT: PASS`.
2. Run `Contents/MacOS/Medusa --auth-test 40`. Press a key, check that the dialog appears, cancel it, press a key again, then unlock with Touch ID.
3. Run it again. Put the displays to sleep (hot corner, or `pmset displaysleepnow` from an ssh session), wait five seconds, press one key, and unlock with Touch ID without pressing anything else. Before the fix the dialog vanished as the displays lit.
4. Run it once more with the dialog up, switch the TV off and on, and check that the dialog is still visible afterwards.
5. Read the trail: `log show --last 10m --predicate 'subsystem == "org.medusa.Medusa.local" AND category == "lock"'`.

## Comments

**2026-11-19.** Steps 1 and 2 ran on `build/Medusa Local.app` with the user at the keyboard, minus the cancel in step 2.

- `--self-test`: `RESULT: PASS`, Shield on 3 displays, event tap created and enabled.
- `--auth-test 40`: locked at 15:41:55.997, `auth dialog requested` at 15:41:58.172 after a key press, `auth outcome=success reaction=unlock` at 15:42:02.153, assertion released.

The real event tap and the real `LAContext` call work after the refactor. Steps 3 and 4 (a dark display, a display change with the dialog up) are the two fixed scenarios and have not been run. The cancel and retry in step 2 has not been run either.
