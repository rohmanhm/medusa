# Stability audit, November 2026

Status: ready-for-human
Branch: `stability-audit-schedule`
Decision trail: [decisions.tsv](decisions.tsv)

## What was asked

The Touch ID dialog sometimes does not unlock and the physical Touch ID key has to be pressed. The screen sometimes does not sleep, and sometimes sleeps when it should not. Audit the app, fix what turns up, and add a way to keep the Mac awake on a schedule.

## How the audit looked

Every Swift source, the specs under `.scratch`, and the uncommitted diff from 2026-09-08 were read. The running app (0.3.1, pid 26639, up since 2026-11-10) was then examined without touching the screen, because the Mac was in use:

- `pmset -g log` for seven days of assertions, display power, and sleep.
- `log show` for the Medusa process and for LocalAuthentication.
- `sample` of the process, and the window list.

Each bug was then reproduced in a test that drives the production code before it was fixed. `swift test` runs 62 tests. The real overlay windows are built 30,000 points off every display, and power assertions are read back through `pmset`.

## What the field data says about the two complaints

**The screen.** No Medusa bug kept the display on or off in the seven days of logs. The pattern is a routine done by hand:

- Each working day from 11 to 17 November a Display awake Session was started by hand in the morning (11:00, 09:40, 07:45, 10:07, 07:05). Four of the five ran exactly 12 hours.
- When it runs out in the evening the display sleeps 3 minutes later with work still in progress (13 Nov: Session ended 19:45:31, display off 19:48:41, woken 19:52:33).
- The Session started next was indefinite and stayed on until the next morning (13 Nov 19:52:45 to 14 Nov 07:17:37). The display was lit all night.

Schedules replace that routine. Two other holders kept the display on after Medusa let go: the Dia browser (`NoDisplaySleepAssertion "Capturing"`) and `coreaudiod` (`preventuseridledisplaysleep`, held 118 hours). Medusa cannot release those. See [issue 04](issues/04-other-apps-keep-the-display-on.md).

**Touch ID.** Three days of LocalAuthentication logs hold no Medusa unlock at all, so the report could not be traced in the field. What the Mac's own settings say is this. `sysadminctl -screenLock status` reads "immediate" and display sleep is 3 minutes. So whenever the displays sleep under a Medusa lock, the macOS lock screen takes over at once and Medusa yields to it, as designed. Medusa's "press any key, then Touch ID" dialog is then not there at all, and the way back in is the macOS lock screen, which a press of the Touch ID key wakes and unlocks.

The display should not sleep under a lock that keeps the Mac awake. Finding 5 is a way it did: lock during a timed Session, the Session runs out, a minute later the kernel turns the shared assertion off, three minutes later the display sleeps. With a 12 hour Session started every morning, that fits a lock in the evening. This chain is an inference from a tested bug and two measured settings. It was not observed.

The code also has two defects that take the dialog away while Medusa itself still holds the lock, findings 2 and 3. Both are reproduced in tests. Finding 3 needs a dark display under a Medusa lock, which "immediate" rules out on this Mac. Finding 2 needs a display change mid-unlock, which the TV can cause. The app now logs the whole unlock path, so the next occurrence can be replayed. See [issue 01](issues/01-watch-a-real-unlock.md).

## Findings fixed on this branch

| # | Finding | Evidence | Fix |
| --- | --- | --- | --- |
| 1 | The Permissions pane polled TCC once a second for the life of the process, Settings window closed or not. | 3600 `TCCAccessRequest` per hour over 11.5 hours of log. `sample` shows `PermissionsPane.body` calling `IOHIDCheckAccess`. The Settings window was off screen. | `fcf6441`. Polls only while a grant is missing. Settings is released when its window closes. Measured on the signed local build with the pane hosted off screen for 6 seconds: 4 requests in the first 0.3 seconds, none after. |
| 2 | A display change while the Touch ID dialog is up rebuilt the Shield above the dialog. Further key presses did nothing, because an auth was already in flight. | Test: rebuilt overlays sat at level 2147483628 instead of 1000. | `33e192b` (red), `1f07332`. |
| 3 | Any wake event cancelled a Touch ID dialog that was already up. A key press on a dark display both wakes it and summons the dialog. | Test: `screensDidWake`, `didWake` and `sessionDidBecomeActive` each cancelled the dialog and raised the Shield. | `d3291d8` (red), `0cff5fe`. The dialog now comes down when sleep begins. |
| 4 | The Lock hold stayed Display awake while Medusa had yielded to the macOS lock screen, so that screen never slept. | Test: `effectiveLevel` stayed `.display` after `systemScreenDidLock`. | `23cbfee`, `5668db6`. System awake while yielded. |
| 5 | A Lock hold that outlived a finite Session kept the Session's kernel timeout. The kernel turned the shared assertion off a minute after the Session ended, and the engine still reported it held. | Test: `pmset` showed a pending `TimeoutActionTurnOff` after the Session ended under a Lock hold. | `5bacfc4` (red), `7f2e9d1`. |
| 6 | Extend turned an indefinite Session into a 15 minute one. | Test. | `235baab` (red), `55b4bbf`. The menu hides Extend for indefinite Sessions. |
| 7 | Until… picked between 23:00 and midnight ended a day late. | Test. | `235baab` (red), `55b4bbf`. |
| 8 | "Show countdown in the menu bar" did nothing. Its guard required that no Session exist. | Code reading. The harness check on it was a search for the word `countdownText` in the source, and passed. | `55b4bbf`. |
| 9 | The engine woke once a second forever with nothing held. | `sample`: `KeepAwakeController` timer firing on an idle app. | `5bacfc4`. It sleeps until the next Schedule window, or for good when there is none. |
| 10 | Nothing was logged, so a field report could not be replayed. | The Touch ID report above. | `42e916f`. See README, "Reading what happened". |
| 11 | The unbundled binary could not load Sparkle under the Swift 6.4 build system, so every documented `--self-test` and `--snapshot` command on a debug build died in dyld. | dyld error on the first run. | `72b1c1a`. |
| 12 | `UNUserNotificationCenter` trapped under `xctest`, which has a bundle identifier but is no app. | Signal 6 on the first test run. | `235baab`. The guard requires an app bundle. |

Commit `7c43b93` is the uncommitted work from 2026-09-08, adopted unchanged: it wakes a display that slept on its own under Display awake, and stops the Shield from dropping a TV during an HDMI renegotiation. It has not been watched on the TV in this audit.

## Open

- [01 Watch a real unlock](issues/01-watch-a-real-unlock.md). A plain lock and Touch ID unlock on the local build passed on 2026-11-19. The two fixed scenarios (a dark display, a display change mid-unlock) have not been seen on a locked screen.
- [02 Two system cancels in a row unlock the Mac](issues/02-two-system-cancels-fail-open.md).
- [03 The Backstop counts awake time only](issues/03-backstop-counts-awake-time.md).
- [04 Other apps keep the display on](issues/04-other-apps-keep-the-display-on.md).
- [05 The harness scripts test a copy of the policy](issues/05-harness-scripts-test-a-copy.md).
- No ticket: the menu-bar countdown counts seconds (`1:02:03`). The Keep Awake spec asked for minutes, updated on the minute. The behavior was left alone and the Settings copy now describes it.

## What was not done

- No release. `scripts/release.sh` was not run and `main` was not touched.
- The display was never put to sleep, and the Mac was locked once, for 6 seconds, in the consented run recorded in issue 01.
- The menu was not looked at on screen. Its strings are tested, its layout is not.
