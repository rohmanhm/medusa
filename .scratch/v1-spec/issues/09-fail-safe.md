# Fail-safe & lockout recovery

Type: grilling
Status: resolved
Blocked by: 01, 02

## Question

Medusa's failure mode is holding the user's machine hostage. Design the recovery story:

- If Medusa crashes while locked: does the tap die with the process (research ticket 01 should confirm) and does the overlay come down? Do we need a watchdog?
- If auth breaks (Touch ID hardware wedge, repeated failures): auto-release after N minutes? Escalating fallback?
- System-reserved escapes (⌘⌥⎋, power button) — do we document them as features or try to soften them?
- Tap auto-disable by timeout: re-enable silently, or treat as "unlock"?
- Remote escape hatch: is SSH-in-and-kill acceptable as the documented last resort?

## Answer

- **Crash while locked:** the tap dies with the process (kernel tears down the mach port), input returns instantly. No separate watchdog process needed for v1.
- **Tap can't be created:** `LockController.lock()` tears down shield + power assertion and reports failure — **fail open**, never a shield that only looks like it blocks.
- **Tap auto-disabled** (`tapDisabledByTimeout`/`ByUserInput`): re-enabled in-callback, plus a 1 s `CGEventTapIsEnabled` watchdog for the post-sleep case the callback misses.
- **Auth broken:** OS-reserved escapes are documented as features in the README — ⌘⌥⎋ Force Quit, power button, and `pkill -f Medusa.app` over SSH. Not fought, because they can't be.
- No auto-release timer in v1; the escape hatches above are the safety net.
