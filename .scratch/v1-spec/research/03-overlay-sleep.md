# Research: Overlays, multi-display & sleep prevention

Ticket: `.scratch/v1-spec/issues/03-overlay-sleep.md`
Date: 2026-07-20

## TL;DR

Borderless `NSWindow` per `NSScreen`, level = `CGShieldingWindowLevel()`, collection behavior `[.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]`, rebuilt on `NSApplication.didChangeScreenParametersNotification`. Keep-awake via `IOPMAssertionCreateWithName` with `kIOPMAssertionTypePreventUserIdleDisplaySleep` (the `caffeinate -d` assertion). The screen stays visible (the whole point is monitoring long-running work), so the overlay should be translucent chrome, not a blackout; capture-blocking via `sharingType = .none` is best-effort only on macOS 15+. On fast user switch the session stops receiving input and the overlay is irrelevant behind loginwindow — re-arm everything on `sessionDidBecomeActiveNotification`.

---

## 1. NSWindow configuration for the lock overlay

### Window level

- `CGShieldingWindowLevel()` "returns the window level of the shield window for a captured display" — the level the window server uses to black out a display captured via `CGDisplayCapture`. Putting a window at (or just above) this level places it above effectively everything user-facing: menu bar, Dock, Spotlight, Notification Center, screen savers. ([Apple docs](https://developer.apple.com/documentation/coregraphics/cgshieldingwindowlevel()))
- Numeric context (measured ladder, [Jim Fisher](https://jameshfisher.com/2020/08/03/what-is-the-order-of-nswindow-levels/), [CGWindowLevel.h](https://gist.github.com/rismay/ab10e87dc10a76c25986d52c65441bf2)):
  - `.normal` = 0, `.statusBar` = 25, `.popUpMenu` = 101, `kCGScreenSaverWindowLevel` = 1000, `.assistiveTechHighWindow` = 1500, `.cursorWindow` = 2147483630, `kCGMaximumWindowLevel` = `INT32_MAX - 16` = 2147483631.
  - The shielding level sits at the very top of this range (just below `kCGMaximumWindowLevel`), i.e. above screen saver and assistive-tech levels. Don't go above cursor level or the pointer can render beneath the overlay — use `CGShieldingWindowLevel()` as-is, not `+1`, which CocoaDev reports as the working recipe ([SetLevel — CocoaDev](https://cocoadev.github.io/SetLevel/)).
- Swift: `window.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))`.
- Peer validation: **lockpaw** (OSS peer) uses exactly "CGShieldingWindowLevel(), the highest level in the system. Above Spotlight, Notification Center, screen savers, everything." ([sorkila/lockpaw](https://github.com/sorkila/lockpaw))
- Softer alternative: `.screenSaver` (1000) is enough to beat all normal app windows and plays nicer with system dialogs, but Spotlight/Notification Center-class UI can appear above it. For "unbreakable", shielding level is the right call; the event tap (issue 02) is the real enforcement anyway.

### Window class & flags

- Borderless window: `styleMask: [.borderless]`, `isOpaque` false + translucent background (see-through) or opaque if configured. Override `canBecomeKey` to return `true` — borderless windows refuse key status by default, and the unlock UI (password field/button) needs it.
- `hidesOnDeactivate = false`, `isReleasedWhenClosed = false`, `ignoresMouseEvents = false` (the unlock button must be clickable — lockpaw deliberately lets mouse moves through the tap for this reason).
- Order with `orderFrontRegardless()` so it shows even when the app is inactive.
- Optional hardening: kiosk-mode `NSApp.presentationOptions` (`.hideDock`, `.hideMenuBar`, `.disableProcessSwitching`, `.disableForceQuit`, `.disableSessionTermination`) — [NSApplication.PresentationOptions](https://developer.apple.com/documentation/appkit/nsapplication/presentationoptions-swift.struct). Mostly redundant given the event tap swallows Cmd-Tab/Cmd-Opt-Esc, but it is defense in depth if the tap dies.

### Spaces & fullscreen apps

`window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]` (add `.ignoresCycle` for tidiness):

- [`.canJoinAllSpaces`](https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior-swift.struct/canjoinallspaces) — window appears on every Space, so switching Spaces while locked can't escape it.
- [`.fullScreenAuxiliary`](https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior-swift.struct/fullscreenauxiliary) — window may show over fullscreen (Space-based) windows; without it the overlay won't render above a fullscreen app/video.
- [`.stationary`](https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior/1419188-stationary) — Mission Control leaves the window alone (like the desktop window).
- Longstanding recipe confirmed on [Apple dev forums thread 26677](https://developer.apple.com/forums/thread/26677) ("window visible on all spaces including fullscreen apps").

### Stage Manager

Stage Manager reads `collectionBehavior`: windows marked `auxiliary`, `moveToActiveSpace`, `stationary`, or `transient` do **not** displace the active window in center stage ([WWDC22 "What's new in AppKit" notes](https://mackuba.eu/notes/wwdc22/whats-new-in-appkit/), [session video](https://developer.apple.com/videos/play/wwdc2022/10074/)). Our `.stationary` + shielding-level borderless window simply draws over the stage; no special handling needed.

### Notch / safe areas

- Size each overlay to `screen.frame` (the full frame includes the camera-housing region). A custom window covering `screen.frame` does cover the area beside/under the notch; only the standard green-button fullscreen API letterboxes below the notch ([Apple forums thread 693315](https://developer.apple.com/forums/thread/693315)).
- Use [`NSScreen.safeAreaInsets`](https://developer.apple.com/documentation/appkit/nsscreen/safeareainsets) ("distances from the screen's edges at which content isn't obscured"; on notched Macs the top inset reflects the camera housing) to keep the unlock UI/status text out of the notch. `safeAreaInsets.top == 0` ⇒ no notch on that screen.

## 2. Multi-display

- **One window per `NSScreen`**: iterate `NSScreen.screens` at lock time, create an overlay per screen with `window.setFrame(screen.frame, display: true)`. lockpaw ships "one overlay window per screen, recreated on hot-plug" ([sorkila/lockpaw](https://github.com/sorkila/lockpaw)).
- **Hot-plug / resolution change**: observe [`NSApplication.didChangeScreenParametersNotification`](https://developer.apple.com/documentation/appkit/nsapplication/didchangescreenparametersnotification) — "posted when the configuration of the displays attached to the computer is changed" (attach, detach, resolution, arrangement, mirroring, Sidecar/AirPlay). Simplest robust strategy while locked: tear down all overlay windows and recreate from the current `NSScreen.screens` (lockpaw's approach). Debounce — the notification often fires several times per reconfiguration.
- On unplug, AppKit migrates orphaned windows to a remaining display on its own, which can briefly stack two overlays on one screen — another reason recreate-on-notification beats trying to patch frames.
- Lower-level alternative if we ever need pre-AppKit granularity: `CGDisplayRegisterReconfigurationCallback` with `NSScreenNumber` from `screen.deviceDescription` ([NSScreen docs](https://developer.apple.com/documentation/appkit/nsscreen), [CocoaDev NSScreen](https://cocoadev.github.io/NSScreen/)). Not needed for v1.

## 3. Keeping the Mac awake

### API

`IOPMAssertionCreateWithName(type, kIOPMAssertionLevelOn, reason, &assertionID)` / `IOPMAssertionRelease(assertionID)`. The human-readable reason string shows up in `pmset -g assertions` — use something like `"Medusa: locked, keeping Mac awake"`. Assertion types ([IOPMAssertionTypes](https://developer.apple.com/documentation/iokit/iopmlib_h/iopmassertiontypes)):

| Type | Effect | caffeinate |
|---|---|---|
| [`kIOPMAssertionTypePreventUserIdleDisplaySleep`](https://developer.apple.com/documentation/iokit/kiopmassertiontypenodisplaysleep) | Display won't idle-sleep; consequently the system won't idle-sleep either | `-d` |
| [`kIOPMAssertionTypePreventUserIdleSystemSleep`](https://developer.apple.com/documentation/iokit/kiopmassertiontypepreventuseridlesystemsleep) | System won't idle-sleep, but display may sleep | `-i` |
| `kIOPMAssertionTypePreventSystemSleep` | Blocks sleep incl. lid close — **valid on AC power only** | `-s` |
| (`kIOPMAssertionTypeNoDisplaySleep` / `NoIdleSleep`) | Deprecated synonyms of the two above — don't use | — |

caffeinate flag mapping per the [caffeinate man page](https://ss64.com/mac/caffeinate.html); `-u` additionally declares user activity (wakes the display, ~5 s default).

### Which one Medusa wants

- **Default: `PreventUserIdleDisplaySleep`** — the pitch is watching builds/renders/agents in real time, so the display must stay lit. This subsumes system idle sleep.
- If we add a "let the display sleep, keep tasks running" option: `PreventUserIdleSystemSleep`.
- "stays awake even with the lid closed" requires the `PreventSystemSleep` class of assertion (`caffeinate -s`), which only holds on AC power; there is no public API that prevents clamshell sleep on battery. Document this limit rather than fight it.
- Keep-awake should be a toggle, acquired on lock / released on unlock. Peer example: [KeepingYouAwake](https://github.com/newmarcel/KeepingYouAwake) is a thin wrapper around exactly these `caffeinate` assertions.

### Long-running tasks underneath

Nothing extra needed: blocking input and drawing overlays does not suspend any process, and assertions only *prevent* sleep. The one real risk to a build/agent is **system** sleep (suspends userland) — display sleep alone doesn't stop work. So even the display-sleep option keeps tasks alive as long as the system-sleep assertion side holds.

## 4. Screen capture: block or stay visible?

- **What `.sharingType = .none` actually buys** ([NSWindow.SharingType.none](https://developer.apple.com/documentation/appkit/nswindow/sharingtype-swift.enum/none)): exclusion from legacy capture (`CGWindowListCreateImage`) and, historically, ScreenCaptureKit. It is *not* reliable anymore:
  - On macOS 15.4+, windows with `sharingType = .none` are captured by ScreenCaptureKit anyway; Apple DTS: "At this time there are no public APIs for preventing screen capture" ([Apple forums thread 792152](https://developer.apple.com/forums/thread/792152)).
  - Tauri tracks the same regression: on macOS 15+ all window contents are composited into one framebuffer that SCK captures directly; "deliberate change by Apple... no known workaround" ([tauri#14200](https://github.com/tauri-apps/tauri/issues/14200)).
  - Even earlier it was leaky — QuickTime screen recording captured "hidden" windows ([Svoboda, "How interview cheating tools hide from Zoom"](https://adamsvoboda.net/how-interview-cheating-tools-hide-from-zoom/)).
- **Recommendation for Medusa**: default `sharingType = .normal` — the overlay *should* appear in recordings/streams. It's honest (viewers see why input is frozen), it matches the visible-screen philosophy, and it avoids shipping a feature (capture invisibility) the OS no longer guarantees. If we later add a "hide overlay from capture" toggle for clean build timelapses, implement it as best-effort `.none` with a documented macOS 15+ caveat. Capture is output-only; neither choice affects the input-blocking security story.

## 5. Login window & fast user switching

- **Switched-out sessions**: "Processes in a switched-out login session continue running as before... However, because they are switched out, they do not receive input from the keyboard and mouse. Similarly... the monitor would appear to be in sleep mode." ([Apple: Supporting Fast User Switching](https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPMultipleUsers/Concepts/FastUserSwitching.html)). Consequences:
  - Our CGEvent tap simply receives no events while switched out — nothing to defend; the loginwindow/other session runs in a separate security context our session-scoped tap can't touch.
  - Our overlay windows are not rendered at the login window or in another user's session; macOS's own lock UI sits above anything we can draw. We cannot and should not try to cover loginwindow.
- **Notifications** ([User Switch Notifications](https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPMultipleUsers/Concepts/UserSwitchNotifications.html)): observe on `NSWorkspace.shared.notificationCenter`:
  - [`sessionDidResignActiveNotification`](https://developer.apple.com/documentation/appkit/nsworkspace/1533531-sessiondidresignactivenotificati) — posted before the session switches out. Keep the locked state; optionally pause UI timers/animations to save resources (Apple's guidance for switched-out apps).
  - [`sessionDidBecomeActiveNotification`](https://developer.apple.com/documentation/appkit/nsworkspace/sessiondidbecomeactivenotification) — posted on switch-in. **Re-arm**: re-enable the event tap (`CGEventTapEnable` — taps can come back disabled, same handling as `kCGEventTapDisabledByTimeout`/`ByUserInput`), `orderFrontRegardless()` every overlay, and re-diff `NSScreen.screens` (displays may have changed while switched out). Power assertions survive; verify and re-create if needed.
  - `CGSessionCopyCurrentDictionary()` / `kCGSessionOnConsoleKey` answers "are we on-console right now?" if we need to poll.
- **Honest scope**: Medusa's lock is an *input shield*, not an authentication boundary. Fast user switching to loginwindow, logging in as another user, or a hard power-off all bypass it by design — Medusa positions itself as protection against accidental/stray input, with Touch ID/password unlock as convenience (lockpaw does the same via `LAContext.evaluatePolicy(.deviceOwnerAuthentication)`).

## Peer OSS reference apps

| App | Relevance |
|---|---|
| [sorkila/lockpaw](https://github.com/sorkila/lockpaw) | Closest peer: shielding-level overlay per screen, recreated on hot-plug; CGEventTap blocks keys/scroll while letting mouse through for the unlock button; IOPMAssertion keep-awake; Touch ID via LAContext with 3-attempt/30 s rate limit |
| [hou-physics/CatLock](https://github.com/hou-physics/CatLock) | Two-tap pattern: permanent listen-only tap for the hotkey + blocking tap while locked; translucent full-screen overlay |
| [ehamiter/Catlock](https://github.com/ehamiter/Catlock) | Menu-bar input blocker; documents the Accessibility-permission requirement |
| [MichalGow/KT-Locker](https://github.com/MichalGow/KT-Locker) | Layered blocking: IOHIDManager + CGEventTap + NSEvent monitors |
| [newmarcel/KeepingYouAwake](https://github.com/newmarcel/KeepingYouAwake) | Canonical caffeinate/IOPMAssertion wrapper for the keep-awake half |

## Recommended v1 shape

1. `OverlayController`: on lock, build one borderless `NSWindow` per `NSScreen` at `CGShieldingWindowLevel()`, `[.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]`, frame = `screen.frame`, unlock UI inset by `safeAreaInsets`, `orderFrontRegardless()`.
2. Subscribe to `didChangeScreenParametersNotification` → debounce → recreate overlays while locked.
3. `PowerAssertionController`: acquire `PreventUserIdleDisplaySleep` on lock (toggle for `PreventUserIdleSystemSleep`; optional AC-only `PreventSystemSleep` for lid-closed), release on unlock.
4. `sharingType = .normal` (visible in recordings).
5. Session notifications → suspend cosmetics on resign, re-arm tap + overlays + assertions on become-active. Document that FUS/loginwindow is outside the threat model.

## Sources

- https://developer.apple.com/documentation/coregraphics/cgshieldingwindowlevel()
- https://jameshfisher.com/2020/08/03/what-is-the-order-of-nswindow-levels/
- https://gist.github.com/rismay/ab10e87dc10a76c25986d52c65441bf2
- https://cocoadev.github.io/SetLevel/
- https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior-swift.struct
- https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior-swift.struct/canjoinallspaces
- https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior-swift.struct/fullscreenauxiliary
- https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior/1419188-stationary
- https://developer.apple.com/forums/thread/26677
- https://mackuba.eu/notes/wwdc22/whats-new-in-appkit/
- https://developer.apple.com/videos/play/wwdc2022/10074/
- https://developer.apple.com/documentation/appkit/nsscreen/safeareainsets
- https://developer.apple.com/forums/thread/693315
- https://developer.apple.com/documentation/appkit/nsapplication/didchangescreenparametersnotification
- https://developer.apple.com/documentation/appkit/nsscreen
- https://developer.apple.com/documentation/iokit/iopmlib_h/iopmassertiontypes
- https://developer.apple.com/documentation/iokit/kiopmassertiontypepreventuseridlesystemsleep
- https://developer.apple.com/documentation/iokit/kiopmassertiontypenodisplaysleep
- https://ss64.com/mac/caffeinate.html
- https://developer.apple.com/documentation/appkit/nswindow/sharingtype-swift.enum/none
- https://developer.apple.com/forums/thread/792152
- https://github.com/tauri-apps/tauri/issues/14200
- https://adamsvoboda.net/how-interview-cheating-tools-hide-from-zoom/
- https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPMultipleUsers/Concepts/FastUserSwitching.html
- https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPMultipleUsers/Concepts/UserSwitchNotifications.html
- https://developer.apple.com/documentation/appkit/nsworkspace/sessiondidbecomeactivenotification
- https://developer.apple.com/documentation/appkit/nsworkspace/1533531-sessiondidresignactivenotificati
- https://github.com/sorkila/lockpaw
- https://github.com/hou-physics/CatLock
- https://github.com/ehamiter/Catlock
- https://github.com/MichalGow/KT-Locker
- https://github.com/newmarcel/KeepingYouAwake
