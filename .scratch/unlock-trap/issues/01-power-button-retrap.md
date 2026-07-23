# Power-button re-trap + cancel dead-end

Type: task
Status: resolved

## Question

User report (2026-07-23): canceling Touch ID sometimes never re-opens the dialog; power-button → system unlock always reopens Medusa and traps the machine until force-shutdown.

## Answer

### Root cause

1. **Power-button re-trap (confirmed, red harness):** `LockController` reaffirmed on `didWake` / `screensDidWake` / `sessionDidBecomeActive` but never observed `com.apple.screenIsUnlocked`. After system auth, `isLocked` stayed true → next wake re-fronted the shield over an unlocked desktop.
2. **Cancel / stuck auth:** `Authenticator.isAuthenticating` had no reset. Sleep mid-dialog or a lost LA completion latched the flag; later cues died in `guard !isAuthenticating`.

### Fix

- `LockPolicy` — pure session/auth decision table (testable without Touch ID)
- Observe `com.apple.screenIsLocked` / `com.apple.screenIsUnlocked` via `DistributedNotificationCenter`
- **Release** on system unlock; **ignore** wake while system lock is up; **reaffirm** only when Medusa still owns the display
- `Authenticator.reset()` invalidates in-flight `LAContext` and clears the busy flag; called on reaffirm, system lock, and unlock

### Proof

```bash
swift scripts/unlock-trap-loop.swift   # 23/23 green
swift build                            # clean
```

Harness also greps production source for the distributed-notification observers so deleting them goes red again.
