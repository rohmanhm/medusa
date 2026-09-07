# Research: Session mechanics — notifications, deadline timers, menu bar countdown

Date: 2026-09-05
Effort: `.scratch/keep-awake/`
Question: For an `LSUIElement` accessory app built by SwiftPM (macOS 13 target, bundled by `scripts/build-app.sh`, also run **unbundled** via `swift run` / `--self-test`): how do we (a) send actionable notifications, (b) hold a deadline across sleep to ±2 s, (c) show a countdown + state icon in the menu bar?

## TL;DR

| Area | Answer | Confidence |
|---|---|---|
| **UserNotifications unbundled** | `UNUserNotificationCenter.current()` **hard-traps** with `NSInternalInconsistencyException: bundleProxyForCurrentProcess is nil`. Guard on `Bundle.main.bundleIdentifier != nil`. Verified by local probe. | Certain — reproduced |
| **Bundle requirement** | A plain `.app` with `CFBundleIdentifier` is enough. Ad-hoc signed, *not* LaunchServices-registered, outside `/Applications` — still works. `LSUIElement` is irrelevant to UN. | Certain — reproduced |
| **Provisional auth** | Wrong tool for us: provisional notifications "don't interrupt … with a sound or banner", they land in Notification Center history only. An "Ending in 5 minutes → Extend" banner would never be seen. Use a real prompt. | High |
| **Actionable "Extend 30 min"** | `UNNotificationAction` + `UNNotificationCategory` + `setNotificationCategories` **at launch**; handle in `didReceive response`. HIG allows up to four buttons. | High |
| **Timers across sleep** | `Timer` **and** `DispatchSourceTimer` are Mach-absolute-time based; that clock **stops during sleep** (Apple DTS, verbatim below). `wallDeadline:` uses `gettimeofday(3)` but is not trustworthy enough to be the authority. | High |
| **Recommended pattern** | Absolute `Date` deadline is the single source of truth; a self-correcting tick re-reads `Date()` and is the authority; wake + clock-change notifications force an immediate re-evaluation. ±2 s falls out of a ≤1 s tick. | High |
| **SF Symbols on macOS 13** | All candidates verified against the on-disk symbol catalog: `cup.and.saucer` (2021), `bolt` (2019), `eye` (2019), `moon.zzz` (2019), `powersleep` (2020), current `eye.trianglebadge.exclamationmark` (2021), `mug` (2022.1 = macOS 13.0). None restricted. Only `cup.and.heat.waves` (2024) is too new. | Certain — local catalog |
| **Countdown text** | `button.attributedTitle` (or `button.font`) with `NSFont.monospacedDigitSystemFont` + `imagePosition = .imageLeading` + `imageHugsTitle = true`. Fixed-width format (`1:23`, not `1 h 23 m`) is what actually kills jitter. | High |
| **"Until…" / "Custom…" picker** | `NSAlert` + `accessoryView` holding an `NSDatePicker` — exactly the pattern `AppDelegate` already uses twice. Popover/panel is a later polish, not v1. | High |

---

## 1. UserNotifications from an accessory SwiftPM app

### 1.1 The unbundled trap — reproduced

Local probe 2026-09-05 (`swiftc` → bare Mach-O, run directly, no `.app`):

```
bundleIdentifier = nil
bundlePath = /…/scratchpad
about to call UNUserNotificationCenter.current()
*** Terminating app due to uncaught exception 'NSInternalInconsistencyException',
    reason: 'bundleProxyForCurrentProcess is nil: mainBundle.bundleURL file:///…/scratchpad/'
	3   UserNotifications  __53+[UNUserNotificationCenter currentNotificationCenter]_block_invoke.cold.2
	7   UserNotifications  +[UNUserNotificationCenter currentNotificationCenter]
```

It is an **ObjC exception thrown from a `dispatch_once` inside `+currentNotificationCenter`** — not catchable from Swift, and the `dispatch_once` means it cannot be retried. `swift run` produces exactly this shape (a bare executable in `.build/<config>/Medusa`, no bundle → `bundleIdentifier == nil`), so `--self-test`, `--lock-test`, `--snapshot-*` and `--motion-probe` all sit on this landmine.

The same probe binary, dropped into a minimal ad-hoc-signed `Probe.app` in `/private/tmp` with only `CFBundleExecutable` / `CFBundleIdentifier` / `CFBundlePackageType` / `LSUIElement`, and never registered with LaunchServices:

```
bundleIdentifier = Optional("org.medusa.probe.unbundledtest")
survived: <UNUserNotificationCenter: 0x9cc80c450>
```

and `getNotificationSettings` returned cleanly (`authorizationStatus = 0` / `.notDetermined`).

**Conclusion.** The requirement is a bundle identifier, nothing more. Neither Developer ID signing, nor `/Applications` residency, nor LS registration is needed. `build-app.sh` already stamps `CFBundleIdentifier` (line 88) and `Resources/Info.plist` already carries `LSUIElement` — nothing in the build needs to change.

### 1.2 The guard

```swift
/// UNUserNotificationCenter.current() throws an uncatchable ObjC exception when
/// the process has no bundle identifier — which is every `swift run` and every
/// --self-test / --snapshot-* entry point. Ask this before touching UN, ever.
static var notificationsAvailable: Bool { Bundle.main.bundleIdentifier != nil }
```

Verified: the guard short-circuits the unbundled probe with no crash. Put it behind a `Notifier` seam so `KeepAwakeController` never names `UNUserNotificationCenter` directly — that keeps the pure-policy + harness pattern intact and lets the harness run headless.

Two further consequences worth writing down:

- The grant is keyed per bundle id, so **`org.medusa.Medusa.local` and `org.medusa.Medusa` are two separate rows** in System Settings → Notifications, and the local build shows as "Medusa Local" (`CFBundleName`, stamped at `build-app.sh:89`). Same split that `build-app.sh`'s header comment already describes for TCC.
- **Sparkle does not use UserNotifications.** `nm -u` / `strings` over `.build/{debug,release}/Sparkle.framework/Versions/B/Sparkle` finds zero `UNUserNotificationCenter` / `UNNotification` references. No category-identifier collision, no delegate fight.

### 1.3 Authorization flow

Apple: *"Make the request in a context that helps people understand why your app needs authorization … Sending the request in context provides a better experience than automatically requesting authorization on first launch"*, and *"The first time your app makes this authorization request, the system prompts the person to grant or deny the request and records that response. Subsequent authorization requests don't prompt the person."* ([Asking permission to use notifications](https://developer.apple.com/documentation/usernotifications/asking-permission-to-use-notifications))

Also: *"Always verify authorization before scheduling notifications"* — check `settings.authorizationStatus` is `.authorized` **or** `.provisional` before every schedule, not just once.

**Provisional (`UNAuthorizationOptionProvisional`, macOS 10.14+, confirmed in `UNUserNotificationCenter.h`) is the wrong choice here.** Apple: *"this code doesn't prompt the person for permission … the first time you call this method, it automatically grants authorization"* but provisional notifications *"don't interrupt the person with a sound or banner, or appear on the lock screen. Instead, they only appear in the notification center's history."* A "Session ends in 5 minutes — Extend?" that only exists in Notification Center history is a notification the user will read after the Mac has already gone to sleep. Ask properly, at first Session start.

### 1.4 Delegate and categories — at launch, not at first Session

`UNUserNotificationCenter.h` is explicit about the delegate:

> *"The delegate must be set before the application returns from `application:didFinishLaunchingWithOptions:`."*

and [Declaring your actionable notification types](https://developer.apple.com/documentation/usernotifications/declaring-your-actionable-notification-types) is explicit about categories:

> *"Declare one or more notification categories at launch time"* … *"All of your action objects must have unique identifiers. When handling actions, the identifier is the only way to distinguish one action from another, even when those actions belong to different categories."*

So the split is: **delegate + `setNotificationCategories` in `applicationDidFinishLaunching` (guarded); `requestAuthorization` deferred to first Session start.** That is a refinement of decision 10, not a contradiction of it.

```swift
// AppDelegate.applicationDidFinishLaunching — guarded, no prompt yet.
guard Notifier.available else { return }
let center = UNUserNotificationCenter.current()
center.delegate = self
let extend = UNNotificationAction(
    identifier: "medusa.keepawake.extend30",     // globally unique
    title: "Extend 30 min",
    options: []                                   // no .foreground: we handle in-process
)
center.setNotificationCategories([
    UNNotificationCategory(
        identifier: "medusa.keepawake.ending",
        actions: [extend],
        intentIdentifiers: [],
        options: []
    )
])
```

`UNNotificationAction.actionWithIdentifier:title:options:` is macOS 10.14+; the `icon:` overload (`UNNotificationActionIcon`) is macOS 12+, so an SF-Symbol action icon is available on our 13.0 floor if we want one (`UNNotificationAction.h`).

### 1.5 Handling the action

```swift
func userNotificationCenter(_ c: UNUserNotificationCenter,
                            didReceive response: UNNotificationResponse,
                            withCompletionHandler done: @escaping () -> Void) {
    switch response.actionIdentifier {
    case "medusa.keepawake.extend30": keepAwake.extend(by: 30 * 60)
    case UNNotificationDefaultActionIdentifier: break   // user clicked the body
    default: break                                       // includes UNNotificationDismissActionIdentifier
    }
    done()   // "Always call the completion handler after you finish handling the action."
}
```

`UNNotificationDefaultActionIdentifier` / `UNNotificationDismissActionIdentifier` are declared in `UNNotificationResponse.h` (macOS 10.14+). The dismiss identifier only arrives if the category opts in with `UNNotificationCategoryOptionCustomDismissAction` — we don't need it.

The app is already running, so there is no cold-launch path to worry about: the action is delivered straight to the live delegate.

### 1.6 `willPresent` — required once we set a delegate

`UNUserNotificationCenter.h`: *"The method will be called on the delegate only if the application is in the foreground. If the method is not implemented or the handler is not called in a timely manner then the notification will not be presented."* The docs sharpen it: *"If your delegate does not implement this method, the system behaves as if you had passed the `UNNotificationPresentationOptionNone` option … If you do not provide a delegate at all … the system uses the notification's original options to alert the user."* ([willPresent](https://developer.apple.com/documentation/usernotifications/unusernotificationcenterdelegate/usernotificationcenter(_:willpresent:withcompletionhandler:)))

We *must* set a delegate to receive `didReceive`, therefore we *must* implement `willPresent` or notifications get silently swallowed whenever Medusa happens to be active — which it is every time `NSApp.activate(ignoringOtherApps:)` runs for Settings, About, or either existing alert (`AppDelegate.swift:113`, `:132`).

```swift
func userNotificationCenter(_ c: UNUserNotificationCenter,
                            willPresent n: UNNotification,
                            withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
    done([.banner, .list, .sound])   // macOS 11+; `.alert` is deprecated since 11.0
}
```

`.banner` / `.list` are macOS 11.0+; `.alert` is `API_DEPRECATED_WITH_REPLACEMENT` since macOS 11 (`UNUserNotificationCenter.h`). Our 13.0 floor means we use the new pair unconditionally, no `#available`.

### 1.7 Presentation reality check, and the denial fallback

The HIG says a notification can present *"up to four buttons"* ([HIG · Notifications](https://developer.apple.com/design/human-interface-guidelines/notifications)) — one "Extend 30 min" is comfortably inside that. But whether the button is visible without a hover is the user's **Banners vs Alerts** choice in System Settings, which we do not control. So: **the Extend action is a convenience, never the only way to extend.** The menu's `Extend ▸` submenu (decision 11) is the load-bearing path.

Denial fallback: `getNotificationSettings` returns `.denied`; we then
1. never call `add(_:)` again this launch,
2. keep the whole feature working menu-only — the menu header line already carries `Awake · 1 h 23 m left`, so "Ending in 5 minutes" degrades to "the countdown is visible in the menu bar",
3. show **one** informative `NSAlert` offering to open `x-apple.systempreferences:com.apple.Notifications-Settings.extension`, latched in `UserDefaults` exactly like `systemLockPreemptWarned`,
4. grey the notification toggles in the Keep Awake settings pane with a footer explaining why.

No dialog on every Session start. This mirrors the existing one-shot-warning convention.

---

## 2. Deadline timers across sleep

### 2.1 What actually happens

The clocks, from the SDK itself:

- `mach/mach_time.h`, comment above `mach_continuous_time()`: *"like mach_absolute_time, but advances during sleep"* — i.e. **`mach_absolute_time()` does not advance during sleep.**
- `dispatch/source.h:715-719` and `man 3 dispatch_source_set_timer`: *"The 'start' argument also determines which clock will be used for the timer: If 'start' is `DISPATCH_TIME_NOW` or was created with `dispatch_time(3)`, the timer is based on up time (which is obtained from `mach_absolute_time()` on Apple platforms). If 'start' was created with `dispatch_walltime(3)`, the timer is based on `gettimeofday(3)`."*
- `man 3 dispatch_time`: *"`dispatch_walltime()` … creating a milestone relative to a fixed point in time using the wall clock"*.

And from Apple DTS (Quinn "The Eskimo!"), which is the statement that settles it:

> *"Both `NSTimer` (`Timer` in Swift) and Dispatch timer sources rely on Mach absolute time. This stops counting when the CPU stops, that is, when the device sleeps. If you run a timer across a sleep, you'll see some oddities on the other side. My general advice is that you remove your timers when sleep is a possibility and reschedule them when that's no longer the case."*
> — [Apple Developer Forums, thread 687170](https://developer.apple.com/forums/thread/687170)

> *"The `NSTimer` API works in terms of wall clocks (for example, the `fireDate` property is an `NSDate`). Last I checked its implementation was based on a monotonic clock … However, that clock stops during system sleep."* … *"Rather than try to reverse engineer all the odd behaviours you can get out of `NSTimer`, my recommendation is that you try to avoid its edge cases entirely."*
> — [Apple Developer Forums, thread 106199](https://developer.apple.com/forums/thread/106199); the same answer recommends observing `NSSystemClockDidChangeNotification` and rebuilding timers.

So, concretely:

| Mechanism | Sleeps past the fire time → | Verdict |
|---|---|---|
| `Timer(fire:)` / `scheduledTimer` | fires **late by the sleep duration** (uptime clock paused) | never the deadline authority |
| `DispatchSourceTimer` armed with `DispatchTime` | same — uptime clock | never the deadline authority |
| `DispatchQueue.asyncAfter(wallDeadline:)` / `schedule(wallDeadline:)` | *documented* as `gettimeofday`-based, so should fire promptly on wake; but developers report it collapsing to the uptime behaviour, and Apple never promises wake-time delivery | useful hint, **not** the authority |

There is no supported way to be woken *by* a passed deadline: `DISPATCH_TIMER_STRICT` only tightens leeway (`dispatch/source.h:332-344`) and explicitly *"may override power-saving techniques employed by the system"* — it does not wake a sleeping Mac.

This is fine, because a passed deadline during sleep is exactly the case decision 6 already resolves: the Mac slept, so it wasn't being kept awake, so the Session is over. We just need to notice promptly on wake.

### 2.2 The recommended pattern

**Absolute `Date` is the only state. Every timer is a hint. Every re-entry point re-reads the clock.**

```swift
private var deadline: Date?            // nil == indefinite
private var tick: DispatchSourceTimer?

private func evaluate() {              // idempotent, cheap, safe to call from anywhere
    guard let deadline else { return refreshMenuBar(remaining: nil) }
    let remaining = deadline.timeIntervalSinceNow
    if remaining <= 0 { endSession(reason: .deadlineReached); return }
    refreshMenuBar(remaining: remaining)
    armTick(for: remaining)
}
```

Three things drive `evaluate()`:

1. **A self-correcting tick.** One `DispatchSourceTimer` on `.main`, re-armed after each fire against the *absolute* deadline, so it cannot accumulate drift. Interval per decision 11: `remaining > 60` → fire at the next whole-minute boundary of the countdown (`deadline.addingTimeInterval(-floor(remaining/60) * 60)`), not "now + 60 s", so the displayed number is never stale; `remaining <= 60` → 1 s. Arm it with `schedule(wallDeadline:leeway:)` so the wall clock is at least *tried*, `leeway: .milliseconds(200)`.
2. **`NSWorkspace.didWakeNotification`** (`NSWorkspace.h:323`, plus `screensDidWakeNotification`, 10.6+ — `LockController.swift:230,242` already observes both, so this is a one-line addition to an existing observer set). On wake: `evaluate()`, which either ends the Session or reaffirms the Hold — the existing `PowerAssertion.reaffirm()` precedent.
3. **`NSSystemClockDidChangeNotification`** (`NSDate.h:12`, macOS 10.6+, on `NotificationCenter.default`). On clock change: cancel the tick and `evaluate()`. This is the case a monotonic-only design gets silently wrong, and it's the case Quinn calls out by name.

Also worth observing `NSWorkspace.willSleepNotification` (`NSWorkspace.h:322`) to tear the tick down before sleep — Quinn's *"remove your timers when sleep is a possibility"* — though `evaluate()` on wake makes it optional rather than load-bearing.

### 2.3 ±2 s

Falls out for free: a 1 s tick that re-reads `Date()` bounds end-of-Session lateness at `tick interval + leeway ≈ 1.2 s`, and the wake path fires within the wake notification's own latency. The precision comes from **re-reading the clock**, not from timer fidelity — which is the whole point.

### 2.4 The belt-and-braces already in the plan

Decision 15's IOKit assertion **timeout** (`kIOPMAssertionTimeoutKey`, research 01) is the right backstop and is unaffected by any of the above: the kernel drops the assertion at the deadline even if every timer in Medusa is wrong or Medusa is hung. Keep it. Set it from the same absolute `Date`.

---

## 3. Menu bar countdown and state icon

### 3.1 SF Symbols — verified against the on-disk catalog

Read from `/System/Library/CoreServices/CoreGlyphs.bundle/Contents/Resources/name_availability.plist`, whose `year_to_release` map gives `2022 → macOS 13.0`, `2022.1 → macOS 13.0`, `2022.2 → macOS 13.3`, `2023 → macOS 14.0`. Anything with a release year **≤ 2022.1 is safe on our 13.0 floor**. Cross-checked against `symbol_restrictions.strings` (605 restricted names) — **none of the candidates is restricted.**

| Symbol | Introduced | macOS | Verdict |
|---|---|---|---|
| `eye.trianglebadge.exclamationmark` (today's icon) | 2021 | 12.0 | safe |
| `cup.and.saucer` / `.fill` | 2021 | 12.0 | safe — reads as "awake" |
| `mug` / `mug.fill` | 2022.1 | **13.0** | safe, but exactly on the floor |
| `bolt` / `bolt.fill` | 2019 | 10.15 | safe |
| `eye` / `eye.fill` | 2019 | 10.15 | safe |
| `moon.zzz` / `.fill` | 2019 | 10.15 | safe — reads as "asleep/idle" |
| `powersleep` | 2020 | 11.0 | safe |
| `zzz`, `timer`, `hourglass`, `lock`, `lock.fill`, `sun.max` | 2019 | 10.15 | safe |
| `lock.display`, `powerplug` | 2021 | 12.0 | safe |
| `bolt.badge.clock` | 2022 | 13.0 | safe, on the floor |
| `cup.and.heat.waves` | 2024 | 15.0 | **too new — do not use** |

Suggested mapping, keeping the Medusa identity intact:

- **idle** (no Hold): `eye.trianglebadge.exclamationmark` — unchanged, this is Medusa's face.
- **awake** (Session and/or Lock hold live, unlocked): `cup.and.saucer.fill`. Unambiguous, matches the category the audience already knows from Amphetamine/caffeinate, and is visually distinct at 16 pt.
- **locked**: `lock.fill` (or keep the eye and rely on the Shield being on screen).

`NSImage(systemSymbolName:accessibilityDescription:)` returns a template image (the repo sets `isTemplate = true` anyway, `MenuBarController.swift:20` — keep that). `NSImage.SymbolConfiguration` is macOS 11+ (`NSImage.h:558`) if we ever want a weight/scale tweak; `NSImage(systemSymbolName:variableValue:accessibilityDescription:)` is macOS 13.0+ (`NSImage.h`) but no time-shaped symbol has useful variable layers, so it's not a countdown ring.

Never construct the image without a nil check — `systemSymbolName:` is failable, and a symbol that vanished would leave a blank status item.

### 3.2 Countdown text without width jitter

```swift
if let button = statusItem.button {
    button.image = icon(for: state)
    button.imagePosition = countdownVisible ? .imageLeading : .imageOnly
    button.imageHugsTitle = true            // macOS 10.12+, NSButton.h:141
    button.font = NSFont.monospacedDigitSystemFont(
        ofSize: NSFont.menuBarFontOfSize(0).pointSize,
        weight: .regular)                    // macOS 10.11+, NSFont.h
    button.title = countdownVisible ? compactRemaining(remaining) : ""
}
```

- `NSImageLeading` is macOS 10.12+ (`NSCell.h:56`); `.imageOnly` when the countdown is off keeps today's appearance byte-identical, which matters because the countdown is default-off (decision 11).
- `imageHugsTitle = true` stops AppKit stretching the icon-to-text gap as the title width changes.
- `monospacedDigitSystemFontOfSize:weight:` is documented to *"always return a system font instance with monospaced digit glyphs"* (`NSFont.h`), which fixes digit width — **but that alone does not fix jitter.** `"1 h 23 m"` → `"59 m"` changes *glyph count*, so the status item still resizes and shoves everything to its left.
- **The actual fix is the format.** Use a fixed-width colon form: `1:23`, `0:59`, `12:00`. Width then changes only when the hour field gains a digit (once, at 10 h) — imperceptible in practice. Reserve the long `Awake · 1 h 23 m left` phrasing for the menu header line, where width is free.
- Keep `NSStatusItem.variableLength` (`MenuBarController.swift:6`). Pinning `length` to a constant would clip rather than stabilise.
- If we ever need per-character control, `button.attributedTitle` with `NSFontFixedAdvanceAttribute` is the escape hatch the `NSFont.h` comment points at.

### 3.3 Refresh cadence

Decision 11's "per minute above 1 min, per second below" is right, with one correction from §2.2: schedule the minute tick **on the countdown's own boundary**, not every 60 s from an arbitrary start, or the displayed minute lags by up to 59 s. Skip the refresh entirely when the countdown is off (default) and no Session is live — the status item then never redraws, same as today.

### 3.4 "Until…" and "Custom…" pickers

Three shapes, in order of cost:

1. **`NSAlert` + `accessoryView`** (`NSAlert.h:131`, macOS 10.5+). An `NSDatePicker` with `datePickerStyle = .textFieldAndStepper`, `datePickerMode = .single`, `datePickerElements = [.hourMinute]` (`NSDatePickerCell.h:16,22,28`) for "Until…"; a two-stepper `NSStackView` for "Custom…" h/m. `NSApp.activate(ignoringOtherApps: true)` then `runModal()` — **this is verbatim the pattern `AppDelegate` already uses twice** (`alertKeepAwakeFailed` at `AppDelegate.swift:102-116`, `alertPreemptRaceLoss` at `:122-133`). Menu actions are delivered after menu tracking ends, so a modal from a menu item is safe. Keyboard works, Escape cancels, the result is synchronous. **Recommended for v1.**
2. **`NSPopover` anchored to `statusItem.button`.** Prettier and more menu-bar-native, but needs the menu dismissed first, needs `NSApp.activate(ignoringOtherApps:)` for an `.accessory` app to take key focus, and needs transient-behaviour and dismissal plumbing. Worth doing later, not worth doing first.
3. **`NSMenuItem.view` hosting the picker inline.** Technically supported — *"A view in a menu item will receive mouse and keyboard events normally"* (`NSMenuItem.h:104`) — but the same comment warns that menu tracking runs in `NSEventTrackingRunLoopMode`, which is where field-editor-based controls like `NSDatePicker`'s text field get awkward. Avoid.

SwiftUI `DatePicker` in an `NSHostingController` is a fourth option and fits the Settings panes' existing SwiftUI idiom, but for a two-field prompt it buys nothing over (1) and adds a window controller.

---

## 4. Sources

- **Local probe, 2026-09-05** — `UNUserNotificationCenter.current()` unbundled (`NSInternalInconsistencyException: bundleProxyForCurrentProcess is nil`) vs. inside a minimal ad-hoc-signed, unregistered `.app` (succeeds; `getNotificationSettings` → `.notDetermined`). Guard on `Bundle.main.bundleIdentifier != nil` verified.
- **Local probe, 2026-09-05** — `nm -u` / `strings` over `.build/{debug,release}/Sparkle.framework/…/Sparkle`: zero UserNotifications references.
- **Local catalog, 2026-09-05** — `/System/Library/CoreServices/CoreGlyphs.bundle/Contents/Resources/name_availability.plist` (`year_to_release`, per-symbol introduction year) and `symbol_restrictions.strings`.
- **SDK headers** (`MacOSX.sdk`, Xcode 26.6) — `UNUserNotificationCenter.h` (delegate-before-launch-returns; `willPresent` semantics; `UNAuthorizationOptionProvisional` macos 10.14; `.banner`/`.list` macos 11, `.alert` deprecated 11), `UNNotificationAction.h`, `UNNotificationCategory.h`, `UNNotificationResponse.h`; `mach/mach_time.h` (`mach_continuous_time` "advances during sleep"); `dispatch/source.h:332-344, 710-719`; `NSDate.h:12` (`NSSystemClockDidChangeNotification`); `NSWorkspace.h:320-326`; `NSStatusItem.h`, `NSStatusBarButton.h`, `NSButton.h:134-141`, `NSCell.h:48-58`, `NSFont.h`, `NSMenuItem.h:101-108`, `NSAlert.h:131`, `NSDatePickerCell.h:15-36`.
- **man pages** — `man 3 dispatch_time`, `man 3 dispatch_source_set_timer`.
- Apple docs — [Asking permission to use notifications](https://developer.apple.com/documentation/usernotifications/asking-permission-to-use-notifications), [Declaring your actionable notification types](https://developer.apple.com/documentation/usernotifications/declaring-your-actionable-notification-types), [`willPresent`](https://developer.apple.com/documentation/usernotifications/unusernotificationcenterdelegate/usernotificationcenter(_:willpresent:withcompletionhandler:)), [HIG · Notifications](https://developer.apple.com/design/human-interface-guidelines/notifications) ("up to four buttons").
- Apple DTS — [forums/thread/687170](https://developer.apple.com/forums/thread/687170) (timers rely on Mach absolute time; it stops during sleep), [forums/thread/106199](https://developer.apple.com/forums/thread/106199) (NSTimer's clock stops during sleep; observe `NSSystemClockDidChangeNotification`).
- In-repo — `Sources/Medusa/MenuBarController.swift`, `AppDelegate.swift:90-134`, `LockController.swift:225-250`, `PowerAssertion.swift`, `main.swift`, `Resources/Info.plist`, `scripts/build-app.sh:39-47,84-90`.

---

## Impact on charting decisions

**Decision 6 (deadlines, not stopwatches) — confirmed, and now load-bearing rather than stylistic.** Apple DTS states outright that both `Timer` and `DispatchSourceTimer` run on a clock that stops during sleep. An absolute `Date` deadline plus re-evaluation on wake isn't a nicety, it's the only correct design. **Add one clause:** re-evaluate on `NSSystemClockDidChange` as well as on wake — a user changing the clock, or NTP stepping it, is the case a pure-monotonic design silently gets wrong, and Quinn names it explicitly. Also make the tick, not the one-shot timer, the authority: `wallDeadline:` is documented as `gettimeofday`-based but is not a promise we should build on.

**Decision 10 (notifications) — confirmed, with two refinements.**
(i) **Split the timing:** delegate and `setNotificationCategories` must run at launch (both Apple-documented requirements), while `requestAuthorization` stays at first Session start as charted. (ii) **Rule out provisional authorization** — it suppresses banners entirely, which would make "Ending in 5 minutes → Extend" invisible. (iii) One consequence to write into the spec: because Banners-vs-Alerts is a user setting we don't control, the notification's Extend button is a convenience and the menu's `Extend ▸` submenu is the guaranteed path. Nothing about `.accessory` policy or Sparkle interferes.

**Decision 11 (menu bar) — confirmed, with one correction and one addition.** Correction: monospaced digits alone do **not** prevent width jitter; the fixed-width `1:23` format is what does, and the verbose `1 h 23 m` phrasing should live only in the menu header line. Addition: the minute-cadence refresh must be scheduled on the countdown's own minute boundary, not every 60 s, or the number reads up to 59 s stale. Icon set is fully available on macOS 13 (`cup.and.saucer.fill` for awake, `lock.fill` for locked, today's `eye.trianglebadge.exclamationmark` for idle); only `cup.and.heat.waves` is out of reach. For "Until…"/"Custom…", use `NSAlert` + `accessoryView` + `NSDatePicker` — the pattern `AppDelegate` already runs twice — and leave `NSPopover` as post-v1 polish.

**No new blockers.** Nothing here requires a change to `build-app.sh`, `Info.plist`, the signing story, or the release pipeline. The one new invariant for the codebase: **nothing may touch `UNUserNotificationCenter` without the `Bundle.main.bundleIdentifier != nil` guard**, or `swift run` and every `--self-test` / `--snapshot-*` entry point dies with an uncatchable exception.
