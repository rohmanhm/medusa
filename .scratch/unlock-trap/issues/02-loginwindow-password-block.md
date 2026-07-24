# Loginwindow password field blocked by Medusa shield + tap

Type: task  
Status: resolved  
Blocked by: None

## Question

User report (2026-07-24): Medusa blocked entering the password to unlock macOS. Force power-button restart was the only way out. Never-trap after system unlock was already fixed (01); this is a second trap on the way *into* the system lock screen.

## Answer

### Root cause

On `com.apple.screenIsLocked` while Medusa was locked, `LockPolicy` returned `.ignore` and the controller only cleared stuck auth / rearmed the cue. It did **not**:

1. Hide the shield (still at `CGShieldingWindowLevel`, above loginwindow)
2. Stop the key-swallowing session tap

So loginwindow could appear under Medusa (or be partially visible) while password keystrokes never reached it — force-shutdown was the only exit.

### Fix

- `LockPolicy.SessionReaction.yield` — new reaction distinct from ignore
- `systemScreenDidLock` while Medusa locked → **yield**
- `LockController.yieldToSystemLock()` — `auth.reset()`, `tap.stop()`, `shield.hide()`; stay notionally locked so system unlock still **releases**
- `reaffirmLock` refuses to run while `systemScreenLocked`; can rebuild tap/shield if they were torn down (post-yield safety, only when system lock is gone)
- Harnesses assert yield (not ignore), and production source must contain `yieldToSystemLock` + `tap.stop()` + `shield.hide()`

### Proof

```bash
swift build
swift scripts/unlock-trap-loop.swift   # 36/36 green
swift scripts/system-lock-preempt-loop.swift  # 33/33 green
.build/debug/Medusa --self-test
```

### Contract delta

See [spec](../spec.md): yield is not ignore.
