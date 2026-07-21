# Research: Input interception & permissions (macOS 15+)

Resolves ticket `.scratch/v1-spec/issues/01-input-interception.md`.

**Scope reminder:** Medusa must *block all* keyboard/mouse/trackpad input (swallow it) while
keeping the Mac awake, then unlock via Touch ID/password. That means an **active,
event-swallowing `CGEventTap`** — this shapes almost every answer below.

---

## 1. CGEventTap specifics

### Creating the tap

`CGEventTapCreate(tap, place, options, eventsOfInterest, callback, userInfo)` returns a
`CFMachPortRef`, or **`NULL` on failure** (missing permission, or requesting a HID-level tap
without root). You wrap it in a run-loop source and add it to a run loop:

```c
CFMachPortRef tap = CGEventTapCreate(
    kCGSessionEventTap,          // location
    kCGHeadInsertEventTap,       // place (front of chain)
    kCGEventTapOptionDefault,    // ACTIVE filter (can modify/swallow)
    mask,                        // eventsOfInterest
    callback, userInfo);
CFRunLoopSourceRef src = CFMachPortCreateRunLoopSource(NULL, tap, 0);
CFRunLoopAddSource(CFRunLoopGetMain(), src, kCFRunLoopCommonModes);
CGEventTapEnable(tap, true);     // taps are enabled on creation, but do it explicitly
```

This is exactly how Hammerspoon installs its tap (`kCGSessionEventTap` +
`kCGHeadInsertEventTap` + `kCGEventTapOptionDefault`).
Source: [Hammerspoon libeventtap.m](https://github.com/Hammerspoon/hammerspoon/blob/master/extensions/eventtap/libeventtap.m)

### Tap location (`CGEventTapLocation`)

| Location | Where in the pipeline | Requirement |
|---|---|---|
| `kCGHIDEventTap` | Point where HID events enter the WindowServer — the *earliest* point, sees everything | **Process must run as root**; `NULL` returned otherwise |
| `kCGSessionEventTap` | Per-login-session stream | Works for a normal (non-root) user with the right TCC grant |
| `kCGAnnotatedSessionEventTap` | Session stream annotated for a specific target app | Non-root |

The CoreGraphics header is explicit: *"Taps may only be placed at `kCGHIDEventTap` by a
process running as the root user. NULL is returned for other users."*
Sources: [CGEventTapLocation](https://developer.apple.com/documentation/coregraphics/cgeventtaplocation),
[CoreGraphics CGEvent.h header docs](https://developer.apple.com/documentation/coregraphics/cgevent/tapcreate(tap:place:options:eventsofinterest:callback:userinfo:)?language=objc)

**Recommendation for Medusa:** use `kCGSessionEventTap`. It requires no root/helper and covers
all keyboard/mouse/trackpad input reaching the session. `kCGHIDEventTap` would catch a few
more things but forces a root helper (LaunchDaemon) and much heavier packaging.

### Active filter vs listen-only (`CGEventTapOptions`)

- `kCGEventTapOptionDefault` — **active filter**: the callback's return value matters. It may
  pass the event through unmodified, modify it, or **discard it by returning `NULL`**.
- `kCGEventTapOptionListenOnly` — **passive**: return value is ignored; you can only observe.

Header text: *"Taps may be passive event listeners, or active filters. An active filter may
pass an event through unmodified, modify an event, or discard an event."*

**Medusa must use `kCGEventTapOptionDefault`** — swallowing input is the whole point.

### Event mask (keyboard + mouse + trackpad)

Build a `CGEventMask` by OR-ing `CGEventMaskBit(type)` for each `CGEventType`. To block
*everything* you want at least:

- Keyboard: `kCGEventKeyDown`, `kCGEventKeyUp`, `kCGEventFlagsChanged`
- Mouse buttons: `kCGEventLeftMouseDown/Up`, `kCGEventRightMouseDown/Up`,
  `kCGEventOtherMouseDown/Up`
- Movement/drag: `kCGEventMouseMoved`, `kCGEventLeftMouseDragged`, `kCGEventRightMouseDragged`,
  `kCGEventOtherMouseDragged`
- Scroll/trackpad: `kCGEventScrollWheel`
- **Media / hardware keys**: `NX_SYSDEFINED` (14) — the "systemDefined" type carries
  volume/brightness/play. It is **not** in the public `CGEventType` enum; you add its bit
  manually (`CGEventMaskBit(NX_SYSDEFINED)`). Capture here is imperfect (see §3).

Trackpad gestures/multi-touch are *not* fully represented as CGEvents — pinch/rotate/swipe
arrive as gestures the tap cannot cleanly see; but taps/clicks/scroll/movement (the things
that "do something") all come through as the mouse/scroll events above, so blocking those is
sufficient for the "nothing happens when you touch the trackpad" goal.
Sources: [CGEventType](https://developer.apple.com/documentation/coregraphics/cgeventtype),
[Hammerspoon #2926 – systemDefined/brightness](https://github.com/Hammerspoon/hammerspoon/issues/2926)

### Swallowing events

Return `NULL` from the callback (only honored for an active/default tap). Passing the event
means `return event;`. This is the standard "swallow all input" primitive.
Source: [Hammerspoon libeventtap.m](https://github.com/Hammerspoon/hammerspoon/blob/master/extensions/eventtap/libeventtap.m)

---

## 2. Which TCC permission — Accessibility vs Input Monitoring

This is the single most confused area on the web; here is the reconciled picture from Apple
DTS (Quinn) forum posts and the Karabiner author's reference examples.

There are **three** distinct TCC services in play:

| TCC service | UI location | Governs | Preflight / Request API |
|---|---|---|---|
| `kTCCServiceListenEvent` ("Input Monitoring") | Privacy & Security → Input Monitoring | Receiving events in a tap | `CGPreflightListenEventAccess()` / `CGRequestListenEventAccess()` |
| `kTCCServiceAccessibility` ("Accessibility") | Privacy & Security → Accessibility | Active event taps that modify/filter, AX API | `AXIsProcessTrusted()` / `AXIsProcessTrustedWithOptions()` |
| `kTCCServicePostEvent` ("Accessibility" pane) | Privacy & Security → Accessibility | *Posting/synthesizing* events (`CGEventPost`) | `CGPreflightPostEventAccess()` / `CGRequestPostEventAccess()` |

Key facts:

- A **listen-only** tap needs only **Input Monitoring** (`CGRequestListenEventAccess`). Quinn
  confirms this is the separate privilege introduced in 10.15.
- An **active tap that modifies/filters/swallows** effectively needs **Accessibility**. Apple
  DTS in thread 744440: Input Monitoring is for listen-only; when you *modify/filter/actively
  control* events you need the full Accessibility privilege. The Karabiner author's official
  `osx-event-observer-examples` repo lists the `cgeventtap-example` as requiring **both**
  *Accessibility* approval **and** (since macOS 10.15) *Input Monitoring* approval.
- `PostEvent`/`CGRequestPostEventAccess` is a *different* thing — it governs **injecting** new
  events, not swallowing existing ones. **Medusa does not need PostEvent** for blocking (it only
  drops events); it would only matter if we synthesize input.
- There is **no dedicated "is my event tap allowed" API**. Quinn's recommended live probe is to
  **attempt `CGEventTapCreate` and check for `NULL`** — more reliable than `AXIsProcessTrusted()`,
  which caches/returns stale values on macOS 13+ (Ventura regression).

**Practical conclusion for Medusa:** request **Input Monitoring** (to receive) **and**
**Accessibility** (because it is an active, event-swallowing tap). Peer active-tap apps do
exactly this. Prompt with `CGRequestListenEventAccess()` and
`AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt: true])`, and treat a `NULL` return
from `CGEventTapCreate` as the ground-truth "not authorized yet" signal.

Sources:
[Apple Forums 744440 (listen vs active)](https://developer.apple.com/forums/thread/744440),
[Apple Forums 727984 (AXIsProcessTrusted stale on Ventura; use tap-create probe)](https://developer.apple.com/forums/thread/727984),
[pqrs osx-event-observer-examples (permission matrix)](https://github.com/pqrs-org/osx-event-observer-examples),
[HackTricks: Input Monitoring / Accessibility TCC](https://hacktricks.wiki/en/macos-hardening/macos-security-and-privilege-escalation/macos-security-protections/macos-input-monitoring-screen-capture-accessibility.html)

### Detecting / querying grant state

- Preflight (no prompt): `CGPreflightListenEventAccess()`, `AXIsProcessTrusted()`.
- Request (prompts + deep-links to the settings pane): `CGRequestListenEventAccess()`,
  `AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt: true])`.
- **Ground truth:** `CGEventTapCreate` returning non-`NULL` *and* the tap staying enabled.
- These grant states **do not update live** for a running process for the CG APIs — the
  Settings pane offers to quit/relaunch the app when you toggle Input Monitoring. Plan for a
  relaunch or a poll (see §4 / peer apps in §6).

---

## 3. What *cannot* be intercepted — the escape hatches the OS reserves

Ordered from "truly impossible" (below the event pipeline) to "conditionally reserved":

1. **Power button / Touch ID button.** Handled by the SMC/firmware and the Secure Enclave,
   *below* the WindowServer. A press/long-press (sleep, force-shutdown ~holding, force-restart)
   **never appears as a CGEvent**, so no tap at any location can see or block it. The Touch ID
   *sensor read* also goes straight to the Secure Enclave — invisible to input APIs. This is by
   design and is Medusa's inherent hardware escape hatch.
2. **Secure Event Input windows.** When any process calls `EnableSecureEventInput` (system
   login window, FileVault pre-boot, fast-user-switching, and *any focused secure text field* —
   `NSSecureTextField`, password fields, many password managers), **keyboard events stop being
   delivered to all event taps and HID seize processes** (TN2150). Consequences:
   - Medusa cannot see/block keystrokes while a secure field elsewhere holds focus.
   - Conversely, this is exactly what protects Medusa's *own* Touch ID/password unlock prompt.
   Source: [TN2150 Using Secure Event Input Fairly](https://developer.apple.com/library/archive/technotes/tn2150/_index.html)
3. **⌘⌥⎋ Force Quit.** Brought up by `loginwindow` and processed with system priority. A
   `kCGSessionEventTap` generally *sees* the keyDown, but swallowing it does **not reliably
   suppress** the Force-Quit UI — Apple reserves this as a user safety hatch. (A root
   `kCGHIDEventTap` gets first crack but still cannot be assumed to fully suppress system
   handling.) Treat Force Quit as an intended escape hatch, not a bug.
4. **Boot / firmware key combos** (Recovery, Safe Mode, NVRAM reset, `⌘⌃power` force restart,
   `⌃⌘Q` lock screen partly) — pre-OS or handled by `loginwindow` at high priority; not tappable.
5. **Globe/Fn key.** Partly observable as `kCGEventFlagsChanged`/systemDefined, but its
   system actions (emoji picker, dictation, input-source switch) are consumed by
   HIToolbox/WindowServer and are unreliable to fully block via a session tap.
6. **Media / hardware function keys** (volume, brightness, play/pause, keyboard backlight):
   delivered as `NX_SYSDEFINED` systemDefined events. A tap *can* register for them, but
   capture is unreliable (Hammerspoon documents brightness keys not arriving via systemDefined),
   and some are consumed before a session tap. Expect partial coverage.
7. **Touch Bar** controls: rendered/handled by a separate process (`ControlStrip`/DFR);
   its virtual buttons are not standard CGEvents and are outside a normal session tap.

The general rule: a `kCGSessionEventTap` sits *inside* the WindowServer session, so anything
handled by firmware, the Secure Enclave, `loginwindow`, or behind Secure Event Input is
outside Medusa's reach. This is why competitor "keyboard cleaner" apps advertise blocking
"most" keys but still leave power/Touch-ID/Force-Quit as ways out.

---

## 4. Tap auto-disable: `kCGEventTapDisabledByTimeout` semantics + re-enable

Two "out-of-band" event types are delivered to your callback (they are *not* input; they are
notifications that the tap was turned off):

- **`kCGEventTapDisabledByTimeout`** — the WindowServer disabled the tap because your callback
  **took too long to return**. For an *active* tap the OS blocks the whole input stream waiting
  on you, so it enforces responsiveness by killing the tap. The exact threshold is
  **undocumented**; community observation puts it in the seconds range (a Ghostty maintainer
  measured ~10–15 s of main-thread stall before the timeout fired; other reports are shorter).
  The safe design assumption: the callback must return in well under a second, every time.
- **`kCGEventTapDisabledByUserInput`** — the tap was disabled by other means (e.g. the user, or
  the system re-evaluating). Also seen when Accessibility is revoked mid-run.

**Re-enable pattern** (all peer apps do this) — handle both in the callback and re-arm:

```c
if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
    CGEventTapEnable(myTap, true);   // re-arm
    return event;
}
```
Source: [Hammerspoon libeventtap.m](https://github.com/Hammerspoon/hammerspoon/blob/master/extensions/eventtap/libeventtap.m)

**Critical caveats for the fail-safe ticket:**

- The disable *callback may not always fire* (e.g. sleep/wake, code-signing/TCC re-eval). A
  "non-nil tap is not a healthy tap." Add a **watchdog**: poll `CGEventTapIsEnabled(tap)`
  periodically (every few seconds) and `CGEventTapEnable(tap, true)` — or recreate the tap — if
  it went dark. This exact failure hits many apps after sleep/wake and after re-signing.
  Sources:
  [Daniel Raffel – silent disable race](https://danielraffel.me/til/2026/02/19/cgevent-taps-and-code-signing-the-silent-disable-race/),
  [Ghostty #11819 – tap dead after sleep/wake](https://github.com/ghostty-org/ghostty/discussions/11819),
  [feedback-assistant #390 – taps stop receiving events](https://github.com/feedback-assistant/reports/issues/390)
- **Never block in the callback.** Because Medusa's tap swallows everything, a slow callback
  freezes *all* system input until the timeout fires — a system-wide hang.
  ([Ghostty #11390](https://github.com/ghostty-org/ghostty/discussions/11390)). Keep the
  callback to a tight decision (block vs pass); do UI/auth work on another thread/run loop.
- **Fail-safe implication:** if the tap can't be kept enabled (permission lost, repeated
  timeouts), Medusa must *fail open* (stop blocking) and surface an error, never leave the user
  with a half-dead tap that intermittently drops input.

---

## 5. Hardened runtime, entitlements & App Sandbox

- **CGEventTap needs no special entitlement.** Access is gated by **TCC user consent**
  (Input Monitoring + Accessibility), not by a code-signing entitlement. There is no
  `com.apple.security.*` key that "enables" event taps.
- **Hardened Runtime**: required for **notarization**. It does *not* block event taps. You do
  *not* need `com.apple.security.cs.*` exceptions for tapping. (Provide a purpose string in
  Info.plist as good practice; the TCC prompt itself is triggered by the API call.)
- **App Sandbox — the important nuance:**
  - A **listen-only** tap *can* run inside the App Sandbox on 10.15+ once the user grants Input
    Monitoring (Quinn confirmed the sandbox now permits it).
  - An **active/modifying tap needs Accessibility**, and **Accessibility is not available to
    App-Sandboxed / Mac App Store apps** — there is no sandbox entitlement for it and App Review
    rejects apps that require it.
  - **Therefore, for Medusa specifically (active, swallowing tap ⇒ Accessibility), the App
    Sandbox / Mac App Store path is effectively a dead end.** Ship as **Developer ID +
    Hardened Runtime + notarized**, distributed outside the Mac App Store
    (direct download, not MAS).
  - Precise phrasing: it is not that "event taps are incompatible with the sandbox" in the
    abstract — it is that the **Accessibility grant an active tap depends on is unavailable
    under the sandbox/MAS**.

Sources:
[Apple Forums 668975 (CGEventTap & App Store)](https://developer.apple.com/forums/thread/668975),
[Quinn: sandbox allows listen tap since 10.15](https://developer.apple.com/forums/thread/744440),
[Configuring the Hardened Runtime](https://developer.apple.com/documentation/xcode/configuring-the-hardened-runtime),
[Lapcat: Hardened Runtime & Sandboxing](https://lapcatsoftware.com/articles/hardened-runtime-sandboxing.html)

Also note: TCC grants are pinned to **code identity (signature)**. Re-signing / ad-hoc builds
create a "new" identity, so a previously-granted permission silently stops working while the
toggle still shows ON. Use a **stable Developer ID signature** to keep grants sticky across
updates. Sources: Daniel Raffel (above), [AltTab code-identity notes](https://github.com/lwouis/alt-tab-macos).

---

## 6. How peer apps structure tap + permission handling

### Hammerspoon — the closest architectural match

- Tap: `CGEventTapCreate(kCGSessionEventTap, kCGHeadInsertEventTap, kCGEventTapOptionDefault, mask, cb, ctx)`.
- Swallow by returning `NULL`, pass by returning the event.
- Callback re-enables on **both** `kCGEventTapDisabledByTimeout` and
  `...ByUserInput`, then returns the event.
- Run-loop source on the main run loop in `kCFRunLoopCommonModes`.
- This is essentially the blueprint Medusa should copy.
Source: [libeventtap.m](https://github.com/Hammerspoon/hammerspoon/blob/master/extensions/eventtap/libeventtap.m)

### Karabiner-Elements — deliberately *avoids* relying on a CGEventTap for blocking

- Architecture: a **root** `Karabiner-Core-Service` daemon **seizes exclusive access to the
  physical keyboard via IOKit HID (device seize)**, modifies events, and re-emits them through a
  **DriverKit virtual HID device** (`org.pqrs.Karabiner-DriverKit-VirtualHIDDevice`). A
  user-level agent handles permissions and watches the focused app via the Accessibility API.
- It uses a CGEventTap only as a *fallback* path (which is why v15.x needed Input Monitoring and
  v16+ folds that into Accessibility).
- **Permissions**: Accessibility (primary, also covers input capture in 16+), a Driver Extension
  approval, and Login-Items/background approval. Runs its input-handling daemons as **root**.
- **Why this matters for Medusa:** a HID-seize + virtual-device design sits *below* the event-tap
  pipeline, so it is immune to the timeout/secure-input disable that limits a session tap — but it
  is vastly heavier (a signed DriverKit system extension needs a special Apple-granted
  entitlement, plus a privileged daemon). For a v1 input-blocker a `CGEventTap` is the right
  trade-off; the DriverKit route is the escape hatch if the tap approach proves too leaky.
Sources:
[Karabiner security architecture](https://karabiner-elements.pqrs.org/docs/help/advanced-topics/security/),
[Required macOS settings](https://karabiner-elements.pqrs.org/docs/manual/misc/required-macos-settings/),
[Karabiner-DriverKit-VirtualHIDDevice](https://github.com/pqrs-org/Karabiner-DriverKit-VirtualHIDDevice)

### AltTab — best-in-class permission lifecycle (not a tap, but the model to copy)

- Detects Accessibility with `AXIsProcessTrustedWithOptions(prompt: false)`.
- **Polls** for grant state (it does not trust live API updates): ~every 5 s before start-up
  (1 s leeway), every 60 s after (relies on distributed notifications), and every 0.5 s while
  the permissions window is open.
- If Accessibility is **revoked while running**, it logs it and calls `App.restart()` —
  because TCC/AX state doesn't reliably refresh in-process.
- Notes the Ventura `AXIsProcessTrusted` stale-value bug and re-polls instead of caching.
- Uses a stable Developer ID signature so grants survive updates.
Source: [AltTab SystemPermissions.swift](https://github.com/lwouis/alt-tab-macos/blob/master/src/macos/SystemPermissions.swift)

---

## Consolidated recommendations for Medusa v1

1. **Tap:** `kCGSessionEventTap` + `kCGHeadInsertEventTap` + `kCGEventTapOptionDefault`;
   mask keyboard (down/up/flags) + all mouse buttons + moved/dragged + scroll (+ `NX_SYSDEFINED`
   best-effort). Swallow with `return NULL`. No root helper needed.
2. **Permissions:** request **Input Monitoring** *and* **Accessibility**; use `CGEventTapCreate`
   returning non-NULL (and staying enabled) as ground truth. Deep-link the user to both panes.
3. **Robustness:** handle `kCGEventTapDisabledByTimeout`/`...ByUserInput` in-callback + a periodic
   `CGEventTapIsEnabled` watchdog; recreate the tap after sleep/wake; keep the callback trivially
   fast (auth/UI off the tap thread); **fail open** if the tap can't stay healthy.
4. **Distribution:** Developer ID + Hardened Runtime + notarization, **outside the Mac App
   Store** (the required Accessibility grant rules out the sandbox/MAS). Stable signature to keep
   TCC grants sticky.
5. **Accept the reserved escape hatches** (power/Touch-ID button, Secure Event Input, ⌘⌥⎋,
   firmware combos) as inherent and document them. Consider a
   DriverKit HID-seize design only if the tap approach proves too leaky in practice.
