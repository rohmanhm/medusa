# Unlock trap — cancel dead-end + power-button re-trap

## Problem

Two related ways Medusa held the machine hostage:

1. **Cancel dead-end** — cancel the Touch ID / password dialog and sometimes it never comes back. Next touch does nothing. Stuck behind the shield.
2. **Power-button re-trap** — press the power button, unlock macOS's own lock screen, and Medusa reappears on top of the now-unlocked desktop. Force-shutdown was the only way out.

## Root cause

- **Power-button path (confirmed):** `LockController` reaffirmed the lock on `didWake` / `screensDidWake` / `sessionDidBecomeActive` but never observed `com.apple.screenIsUnlocked`. After system auth, `isLocked` stayed `true`, so the next wake re-fronted the shield over a session the user already paid for.
- **Cancel / stuck auth (contributing):** `Authenticator.isAuthenticating` had no reset path. Sleep mid-dialog or a lost LA completion left the flag latched; every later cue died in `guard !isAuthenticating`. Cancel itself re-armed correctly when the completion fired — the hole was the stuck flag + missing system-unlock release.

## Contract (never trap)

| Event | While Medusa locked | Action |
| --- | --- | --- |
| User cancel / fingerprint miss | yes | Stay locked, re-arm cue |
| `com.apple.screenIsLocked` | yes | Latch flag; clear stuck auth; do **not** re-front |
| Wake while system lock is up | yes | **Ignore** (don't cover loginwindow) |
| `com.apple.screenIsUnlocked` | yes | **Release** Medusa |
| Wake, no system lock | yes | Reaffirm tap + assertion + shields; clear stuck auth |
| System can't present auth (×2) | yes | Fail open |

## Feedback loop

```bash
swift scripts/unlock-trap-loop.swift
```

Pure decision-table + source-observer check. No Touch ID required. Exit 0 = green.

## Fix

- `LockPolicy` — pure session/auth decision table
- `LockController` — observe distributed screen lock/unlock; release on system unlock; suppress reaffirm over system lock; clear stuck auth on reaffirm
- `Authenticator.reset()` — invalidate in-flight `LAContext` and clear the busy flag
