# Overlays, multi-display & sleep prevention

Type: research
Status: resolved

## Question

How do we render an unbreakable lock overlay on every display while keeping the Mac awake?

- NSWindow configuration for a lock screen: window level (`CGShieldingWindowLevel`?), collection behavior across Spaces and fullscreen apps, Stage Manager interaction, covering notch/safe areas.
- Multi-display: one window per `NSScreen`, display hot-plug/unplug and resolution-change handling while locked.
- Keeping the machine awake: IOKit power assertions (`IOPMAssertionCreateWithName` kinds — prevent display sleep vs system sleep), `caffeinate` equivalence, and letting long-running tasks (builds, agents) continue underneath.
- Should the overlay block screen capture (`NSWindowSharingType.none`) or stay visible in recordings?
- Login window / fast-user-switch behavior: what happens to overlay + tap when the session deactivates.

Findings file: `.scratch/v1-spec/research/03-overlay-sleep.md`

## Answer

- Overlay: one borderless `NSWindow` per `NSScreen`, level = `CGShieldingWindowLevel()` (top of the range, ~2147483630 — above screen saver 1000 and assistive-tech 1500; don't add +1 or the cursor can hide). Override `canBecomeKey`, order with `orderFrontRegardless()`.
- `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]` covers all Spaces and fullscreen apps; `.stationary` also keeps Stage Manager from treating it as a stage window. Frame = `screen.frame` (covers the notch region); inset unlock UI by `NSScreen.safeAreaInsets`.
- Multi-display: rebuild all overlays on `NSApplication.didChangeScreenParametersNotification` (debounced) — the lockpaw approach, "recreated on hot-plug".
- Keep-awake: `IOPMAssertionCreateWithName` with `kIOPMAssertionTypePreventUserIdleDisplaySleep` (= `caffeinate -d`, also blocks system idle sleep) as the default; `PreventUserIdleSystemSleep` (`-i`) if display may sleep; lid-closed needs `PreventSystemSleep` (`-s`, AC only). Tasks continue regardless — only system sleep suspends them.
- Screen capture: the screen stays fully visible for monitoring; recommend `sharingType = .normal` (overlay visible in recordings). `.none` is broken on macOS 15.4+ anyway (ScreenCaptureKit ignores it; Apple DTS confirms no public API) — offer only as a best-effort toggle.
- Fast user switch: switched-out sessions get no input events and aren't rendered, so the tap/overlay are inert behind loginwindow (can't and shouldn't cover it). Re-arm tap + overlays + assertions on `NSWorkspace.sessionDidBecomeActiveNotification`. The lock is an input shield, not an auth boundary.

Full findings with citations: [research/03-overlay-sleep.md](../research/03-overlay-sleep.md)
