# 02 — Settings + preempt monitor + auto-lock wire-up

Type: task  
Status: resolved  
Blocked by: 01 — Policy + red/green harness

## What to build

End-to-end opt-in: Settings toggle + idle picker; a monitor that idle-polls and best-effort swallows ⌃⌘Q; auto-locks that force keep-awake; one race-loss warning; never touch loginwindow; never-trap unchanged.

## Acceptance criteria

- [x] Toggle default off; idle default 5 minutes; live apply without relaunch.
- [x] Idle ≥ threshold while unlocked → Medusa lock with keep-awake forced.
- [x] Manual lock still respects Keep Awake toggle.
- [x] ⌃⌘Q best-effort swallow → same auto-lock path when possible.
- [x] System lock while unlocked + setting on → at most one warning; no shield over loginwindow.
- [x] System unlock still releases Medusa.
- [x] `--self-test` PASS; policy harness PASS.

## Answer

Shipped in tree: `SystemLockPreemptMonitor`, Settings → General “Engage Medusa when idle”, `lock(forceKeepAwake:)`, race-loss alert once. No loginwindow paths.
