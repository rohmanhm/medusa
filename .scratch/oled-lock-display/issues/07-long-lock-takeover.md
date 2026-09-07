# Long lock handed to macOS (fail-safe + keep-awake)

Type: task
Status: resolved
Blocked by: 03

## Question

Field report (2026-07-22): after locking, motion/dim seemed dead, the Medusa shield disappeared, and macOS's own lock screen took over — keep-awake looked broken.

## Answer

Root cause was **not** broken OLED drift/dim math (snapshot geometry still matches the zigzag model; dim alpha 0.5; assertion holds past `displaysleep=3` under `--lock-test`).

Smoking gun: **default fail-safe auto-unlock was 30 minutes**. `LockController.startBackstop()` calls `unlock()` → `shield.hide()` + `power.end()`. On this machine (`displaysleep 3`, `screenLock delay is immediate`) the cascade is:

1. Medusa locks, holds `PreventUserIdleDisplaySleep`
2. Wander/dim run while locked
3. t=30m backstop silently unlocks Medusa
4. t≈33m system display sleep → immediate macOS lock UI
5. User returns → "lock gone / keep-awake failed / protection didn't work"

### Fix shipped in tree

1. **Default backstop 30m → 4h** (`AppSettings.registerDefaults`, Settings picker order + copy). Existing installs with a written `backstopMinutes` keep their value until changed — local domain was set to 240 during verify.
2. **Keep-awake failure is no longer silent** — `PowerAssertion.begin()` returns success; `onKeepAwakeFailed` surfaces a one-shot alert (shield lowered via `withShieldLowered`).
3. **Sleep/wake/session re-arm** — while locked, `didWake` / `sessionDidBecomeActive` / `screensDidWake` reaffirm the power assertion, re-enable the event tap, and re-front overlays without tearing motion/dim state.

### Verification (no long human lock)

- `swift build -c release` clean; `./scripts/build-app.sh` assembles
- `--self-test` PASS
- Prior investigation: assertion held at t=190s under lock-test; backstop path drops assertion on fire (`--auth-test 12`)
