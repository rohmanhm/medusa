# Amphetamine feature & defaults audit (parity map)

**Context.** Medusa is cloning Amphetamine's keep-awake feature set deliberately (see [map.md](../map.md)). This file records what Amphetamine 5.3.2 actually ships and what its **defaults** are, so the charting decisions can be graded against a real product rather than a memory of one. Medusa vocabulary (Session, Hold, End condition, Awake level, Preset, Battery guard) is per [CONTEXT.md](../../../CONTEXT.md).

**Sourcing note.** Amphetamine's official support portal (`iffy.freshdesk.com`) is now **login-gated** — it answers every article URL with "Portal is currently not accessible". Every support-article claim below is therefore cited to its canonical URL *and* to the Wayback snapshot actually read (2026 captures). `https://iffy.app/amphetamine/` 404s; `iffy.app` is now an unrelated site, so the developer site is dead and the App Store listing is the live first-party page.

Amphetamine **5.3.2 is installed on this Mac**, so three further primary sources were read directly out of the shipped bundle: `Contents/Info.plist`, `Contents/Resources/Amphetamine.sdef`, and `Contents/Resources/en.lproj/{Localizable,MainMenu}.strings`. Those give exact UI copy and prove absences (no URL scheme, no Shortcuts extension) that no web page states.

**How "default" was established, and its limits.** Defaults marked ✅ are stated in first-party docs or provable from the bundle. Defaults marked ⚠️ come from the live preference file `~/Library/Containers/com.if.Amphetamine/Data/Library/Preferences/com.if.Amphetamine.plist` on this machine — the values are real but the user could in principle have changed any of them; where a ⚠️ value is corroborated by the App Store screenshot or by doc phrasing, that is said. Amphetamine builds its `registerDefaults` dictionary in code (the binary contains the key names as bare C strings and no embedded plist), so a pristine factory dump is not extractable without launching a fresh container. **No forum/Reddit/MacRumors source was needed; nothing below is secondary.**

---

## 1. Session types

Menu structure, verbatim from Amphetamine's own App Store screenshot ([listing](https://apps.apple.com/us/app/amphetamine/id937984704?mt=12)):

```
Start New Session:
  Indefinitely                 ⌘I
  Minutes                       ▸
  Hours                         ▸
  Other Time/Until              ▸
  While App is Running          ▸
  While File is Downloading…   ⌘F
```

| Feature | Amphetamine behavior | Amphetamine default | Medusa v1 |
| --- | --- | --- | --- |
| Indefinitely | Session with no End condition; AppleScript `session time remaining` returns `0` for "infinite duration" | The **Default Duration** ships as *Indefinitely* ✅ | **in** (End condition, decision 5) |
| For a duration | Two fixed submenus: **Minutes** 5→60 in 5-minute steps, **Hours** 1→12 plus 24 | n/a (fixed list) ✅ | **in** — but Medusa's list is 6 editable Presets (decision 13), not Amphetamine's 24 fixed ones |
| Preset list editable? | **No.** The Minutes/Hours items are baked into `MainMenu.nib`; the only user-supplied time is the one-off "Other Time/Until…" sheet ("Enter time for the new duration:"), remembered in `Custom Time Single-Use Hours/Minutes`. (Amphetamine **3** had user "durations"; the v5 migration alert still names them.) | — | Medusa's **editable Presets** are an invention, not parity |
| Until a clock time | "Other Time/Until…" — arbitrary end time; `session time remaining` returns `-2` for date-based sessions | — | **in** (decision 5) |
| While an app is running | Picker of running apps, searchable, ⟳ refresh. Sandboxing means only *apps* are listed; **Amphetamine Enhancer** is what "[g]ives Amphetamine 5.0+ the ability to use all running processes" | — | **decide-in-05** (Medusa's audience runs `claude`/`codex`/`xcodebuild`, i.e. exactly the processes Amphetamine can't see without a helper) |
| While a file is downloading | ⌘F; watches a download | — | **out** |
| Trigger sessions | Automatic start/end from criteria (§5) | Triggers **off** (`Enable Triggers = 0` ⚠️) | **out** |
| Extend | Menu item "Extend session by" *value* + *interval*; a sound can play on extend | Last-used extension remembered; observed `Last Selected Extension Value = 15`, `Interval = 0` (minutes) ⚠️ | **in** (decision 11 `Extend ▸` +15m/+30m/+1h) |
| One session at a time | AppleScript doc: "If a session is already running when Amphetamine receives an AppleScript command to start a new session, the existing session will end and a new one will be started". Hot-key equivalent is a setting: "If a session is already running: End the session / End the session and start a new session" (`DefaultHotkeyAction = 0` ⚠️) | — | Medusa differs by design: **one engine, many Holds** (decision 3) |

Sources: [Amphetamine 101](https://iffy.freshdesk.com/support/solutions/articles/48000078454-amphetamine-101) ([snapshot](https://web.archive.org/web/20260609090425id_/https://iffy.freshdesk.com/support/solutions/articles/48000078454-amphetamine-101)) · [AppleScript Documentation](https://iffy.freshdesk.com/support/solutions/articles/48000078223-applescript-documentation) ([snapshot](https://web.archive.org/web/20260609085655id_/https://iffy.freshdesk.com/support/solutions/articles/48000078223-applescript-documentation)) · [Amphetamine Enhancer README](https://github.com/x74353/Amphetamine-Enhancer) · `MainMenu.strings`, `Amphetamine.sdef` (5.3.2 bundle).

---

## 2. Session options and their defaults

Amphetamine calls these "Non-Trigger Session" defaults (Preferences → Sessions → Session Defaults); every one of them is also overridable **live**, per session, from the menu's "Current Session Details" section.

| Option (exact label) | Meaning | Default | Medusa v1 |
| --- | --- | --- | --- |
| `Allow display sleep` | Off = display kept lit. Two assertions: doc says "one to keep your display awake (optional), and one to keep your system awake (required)" — named `Amphetamine - Display (Single Use)` / `(Trigger)` in `pmset -g assertions` | **Unchecked** — display kept awake ✅ (App Store screenshot; `Allow Display Sleep = 0` ⚠️) | **in** — this *is* Medusa's Awake level (decision 4); Amphetamine's default matches Medusa's "Display awake" default |
| `Allow screen saver after … of inactivity` | Amphetamine starts the screen saver itself after N idle minutes; has an Exceptions… list (e.g. Screen Sharing/VNC) | **Unchecked**; delay observed 5 min ⚠️ | **out** |
| `Allow system sleep when display is closed` | Unchecking it = Closed-Display Mode. Doc: "Uncheck the box labeled 'Allow system sleep when display is closed.'" | **Checked** — i.e. Closed-Display Mode **off** ✅ (screenshot shows it as the only ticked box; `Allow Closed-Display Sleep = 1` ⚠️) | **out** |
| Closed-Display Mode requirements | "Generally, an external display, keyboard, mouse, and power adapter must all be connected to your Mac for Closed-Display Mode to be enabled. Amphetamine can override these requirements temporarily" / "your Mac will not need to have a display, keyboard, mouse/trackpad, or power adapter connection … using a publicly-accessible API to disable Apple's requirements" | — | **out** |
| `End session if charge (%) is below` | Battery guard. Slider; "Move the slider all the way to the right to end sessions any time the power adapter is not connected." Applies to **non-Trigger sessions only** | **Off**; threshold sits at **10 %** (`End Session On Low Battery = 0`, `Low Battery Percent = 10` ⚠️) | **in** (Battery guard, decision 9) |
| `Prompt before ending a session` | Ask first, with an option to continue and ignore the charge | Off (`Always Ask to End For Low Battery = 0` ⚠️) | **out** for v1 (map says notify, don't prompt) |
| `Ignore charge (%) if power adapter is connected` | Guard suspended while plugged in | Off (`Ignore Battery on AC = 0` ⚠️) | folded into Medusa's Battery guard definition ("while unplugged") |
| `Start a new session if reconnected` | Auto-restart a session that died from low battery, once the adapter is reconnected | Off (`Restart DD Session on AC Reconnect = 0` ⚠️) | **out** |
| `End session when Mac is forced to sleep` | "Forced sleep includes any situation where you take an action to put your Mac to sleep such as clicking  → Sleep, or using a keyboard shortcut/hot key." | **Off** (`End Sessions On Forced Sleep = 0` ⚠️) | related to decision 6 |
| `End Time Calculation: Use timer / Use system clock` | Verbatim: "let's say you select 'Use timer' and then start a session for 3 hours. Then you immediately sleep your Mac for 2 hours. When your Mac wakes, the session will still have 3 hours remaining … if you had instead selected 'Use system clock' only 1 hour would be remaining." | Index `0` (`Session End Time Calcuation = 0` ⚠️; which label index 0 maps to is **not** verified) | Medusa **hardcodes** the system-clock reading (decision 6) — Amphetamine makes it a preference |
| `End session when switching accounts` | Fast user switching ends the session | Off (`End Sessions when FUS = 0` ⚠️) | **out** |
| `Start session when Amphetamine launches` | Uses the Default Duration | Off (`Start Session At Launch = 0` ⚠️) | **in** — Medusa's "Start Keep Awake when Medusa starts", default off (decision 8) ✔ parity |
| `Start session after waking from sleep` | — | Off (`Start Session On Wake = 0` ⚠️) | **out** |
| `Lock screen after … of inactivity` / `Lock screen immediately after display is closed` | Amphetamine locks the *system* screen | Off; delay 60 (`Lock Screen After Inactivity = 0`, `Lock Screen Inactivity Delay = 60` ⚠️) | **out** for Keep Awake — Medusa already owns this ground with **Preempt** |
| `Enable Mouse Movement` / `Move cursor every …` | Jiggles the cursor | Off; interval 60 s, after 300 s idle ⚠️ | **out** |
| **Drive Alive** | Own Preferences tab. "keeps the drives connected to your Mac awake by periodically writing a tiny amount of data to each drive"; per-drive "Always Keep Drive Alive"; "Wake drives every **10** seconds" | Off (`Enable Drive Alive = 0`, `Drive Wake Interval = 10` ⚠️) | **out** |

Sources: [Amphetamine Closed-Display Mode](https://iffy.freshdesk.com/support/solutions/articles/48001077199-amphetamine-closed-display-mode) ([snapshot](https://web.archive.org/web/20260421024912id_/https://iffy.freshdesk.com/support/solutions/articles/48001077199-amphetamine-closed-display-mode)) · ["Amphetamine Does Not Keep My Mac Awake"](https://iffy.freshdesk.com/support/solutions/articles/48000078314--amphetamine-does-not-keep-my-mac-awake) ([snapshot](https://web.archive.org/web/20260609085958id_/https://iffy.freshdesk.com/support/solutions/articles/48000078314--amphetamine-does-not-keep-my-mac-awake)) · ["My Mac's Display Is Not Sleeping"](https://iffy.freshdesk.com/support/solutions/articles/48000078418-my-mac-s-display-is-not-sleeping) ([snapshot](https://web.archive.org/web/20260609084821id_/https://iffy.freshdesk.com/support/solutions/articles/48000078418-my-mac-s-display-is-not-sleeping)) · ["Screen Locks When Accessing Mac Remotely"](https://iffy.freshdesk.com/support/solutions/articles/48000144720-screen-locks-when-accessing-mac-remotely) · `en.lproj/Localizable.strings` (5.3.2).

---

## 3. Notifications and sounds

The critical finding: **Amphetamine has no "your session ends in N minutes" warning, and it deliberately deleted manual session start/end notifications.**

| Feature | Amphetamine behavior | Default | Medusa v1 |
| --- | --- | --- | --- |
| Manual session start/end notification | **Removed in Amphetamine 4.** Verbatim: "This option has been removed from Amphetamine⁴ and there are no current plans to reintroduce it. … For the most part, manual session notifications were redundant. Manual session start/end requires you to take some action. Amphetamine's menu bar icon updates to indicate a session state change" | gone ✅ | Medusa plans "Keep Awake ended", default on (decision 10) — **divergence** |
| `Notify when Trigger/scheduled sessions auto-start` / `…auto-end` | Notifications for sessions the user did *not* start by hand | **On** (`Enable Session Auto Start/End Notifications = 1` ⚠️) | Medusa has no Triggers → **out**, but the *principle* (notify only for things you didn't do yourself) is the interesting part |
| `Session Reminders: Remind every N minutes` | "Check this box to have Amphetamine deliver a notification/reminder on a regular interval while any session is running." Menu shows "Next reminder in %li minutes" | **Off**; interval 60 min (`Enable Session Notifications = 0`, `Session Notification Interval = 60` ⚠️) | Medusa has no periodic reminder; nearest analogue to its ending-soon nudge |
| Ending-soon lead time | **Does not exist** — no string, no preference key in 5.3.2 | — | Medusa's "Ending in 5 minutes" + **Extend** action has **no Amphetamine precedent** |
| `Remove notifications after delivery` | Auto-clears Notification Center clutter "especially if you have Session Reminders enabled" | On (`Auto Remove Notifications = 1` ⚠️) | worth copying if Medusa ships reminders |
| Closed-Display Mode warning tone | "Play closed-display warning tone", "Repeat tone every …", "Momentarily set system volume to …". Won't play "if your Mac's power adapter and an external display are connected" | Off; repeat 300 s, volume 5 (`Enable CDM Warning = 0` ⚠️) | **out** (CDM is out) |
| Sounds | Built-ins (Coffee pour, Pop top, Rattle, Heartbeat, Default system sound…) + user-added files. Three switches: with reminders/notifications, on any session start or end, on extend | Sound switches on, sound choice `0` ⚠️ | **out** (map: sounds out of scope) |
| "Session ended because…" copy | Reason strings shipped: `Session duration has elapsed` · `End time (%@) has passed` · `Battery charge is below %li%%` · `Battery is not connected to power adapter` · `Your Mac's battery is below %@` · `Timed session has ended` · `Trigger session has ended` · `Session has ended` · `Your Mac will sleep on its normal schedule` | — | **precedent to copy** for Medusa's end-of-Session copy |

Sources: [Notifications in Amphetamine](https://iffy.freshdesk.com/support/solutions/articles/48000078311-notifications-in-amphetamine) ([snapshot](https://web.archive.org/web/20260414204911id_/https://iffy.freshdesk.com/support/solutions/articles/48000078311-notifications-in-amphetamine)) · `en.lproj/Localizable.strings` (5.3.2).

---

## 4. Menu-bar UX

| Feature | Amphetamine behavior | Default | Medusa v1 |
| --- | --- | --- | --- |
| Click behavior | Two radio options: `Left click (right click shows menu)` / `Right click (left click shows menu)`. First-run copy: "Clicking on Amphetamine in the menu bar will show Amphetamine's menu. **Right clicking (or control clicking) will start or stop a keep-awake session.**" | Left click = menu, right/⌃ click = quick-start (`Status Item Click = 0` ⚠️, matches the copy) ✅ | Medusa has one status item with a submenu (decision 11); a right-click quick-start is free parity worth considering |
| Quick-Start a Session | Preferences group labelled "Quick-Start a Session:" with the hint "↳ Uses Default Duration" | — | decision 13 |
| **Default Duration** | "used throughout Amphetamine when a session duration is not otherwise provided". Minimum 1 minute ("Default duration cannot be less than one minute.") | **Indefinitely**, verbatim: "start a session that will run using your default duration (**indefinitely by default**; change in Preferences → Sessions → Non-Trigger Sessions)" ✅ | decision 13 says Indefinitely ✔ **parity confirmed** |
| Show current session details | Header block in the menu: time remaining, "Manual Activation" / "AppleScript activation" / Trigger name, plus the live option checkboxes and `End Current Session ⌘X` | **On** (`Show Session Details In Menu = 1` ⚠️) | decision 11's disabled header line ✔ parity |
| Show session time remaining **in the menu bar** | Text beside the icon; formats: `Letter notation format (8h 15m)` / `Standard format (08:15)`, `Include seconds`, `Use 24-hour clock`, small/standard font | **Off** (`Show Session Time In Status Bar = 0` ⚠️) | decision 11's countdown, **default off** ✔ parity confirmed |
| Indeterminate sessions | Menu reads `Indeterminate time remaining` for indefinite/app-based/download sessions | — | Medusa's `· indefinitely` header |
| Icons | ~17 built-in styles (Pill, Pill outline, Caffeine, Coffee Cup/Carafe/tin, Tea Kettle, Molecule, Owl/Big/Little, Eye, Sun & Moon, Emoji, Defibrillator, Heartbeat, Spoon and cup, Zzz!!!) plus drag-and-drop `Custom image…` with separate Inactive/Active images and `Use low opacity when inactive` | Pill (`Icon Style = 0` ⚠️) | **out** (custom icon packs out of scope); Medusa's idle/awake/locked icon states mirror Amphetamine's Inactive/Active pair |
| Dock icon | `Hide Amphetamine in the Dock`; app is `LSUIElement` | Hidden (`Hide Dock Icon = 1` ⚠️) | Medusa is already accessory-only |

Sources: [Amphetamine 101](https://iffy.freshdesk.com/support/solutions/articles/48000078454-amphetamine-101) · `en.lproj/{Localizable,MainMenu}.strings`, `Info.plist` (5.3.2).

---

## 5. Hot keys — and whether they ship assigned

Amphetamine has a whole **Hot Keys** preferences tab. Six recordable global chords (recorder is the bundled `MASShortcut.framework`):

1. **Start or End Session** — "The Default Duration … will be used for the session's duration."
2. **Start Session with duration:** — a specific duration you configure (`Custom Time HotKey Hours/Minutes/Seconds`)
3. **End Session**
4. **Open Menu** — "useful to quickly check the session and Drive Alive details … or to quickly navigate or select menu items using the arrow keys"
5. **Toggle Allow Display Sleep** — per-session if one is running, otherwise flips the preference
6. **Toggle Allow Screen Saver** — same shape

Plus a policy switch: `If a session is already running:` → *End the session* / *End the session and start a new session*.

**Shipped assigned? No.** ✅ The preference file on this install contains **no MASShortcut key at all** — every other feature the user touched left a key behind, and the hot-key store is simply absent. Each hot key's help text is written for an unrecorded chord ("After recording the key combination for this hot key…"), and warns "If you aren't able to record your desired hot key combination, that means that the key combination is already in use elsewhere by another app."

Note: the `⌘I` / `⌘X` / `⌘F` / `⌘Q` marks in the menu are **menu key equivalents**, live only while the menu is open — not global hot keys.

→ Medusa decision 12 (a second recordable chord, **default unassigned**) is exact parity, and Amphetamine's list suggests a future *toggle Awake level* chord.

Source: `en.lproj/{Localizable,MainMenu}.strings`, `Contents/Frameworks/MASShortcut.framework`, live preference file (5.3.2).

---

## 6. Triggers — the full list (all **out** of Medusa v1)

A Trigger is "criteria sets that cause a session to automatically start or end by itself"; **all** criteria in one Trigger must evaluate true, and any one Trigger firing starts a session. Each Trigger carries its own display-sleep / screen-saver / closed-display options that "override the choices you have made in Preferences → Sessions → Non-Trigger Sessions". Hard limit, stated plainly: "In order for a Trigger to start a new session, your Mac must already be awake. … Amphetamine cannot wake a Mac that is already asleep."

Criteria, from the App Store listing plus the criterion names in the bundle: external display connected · display mirroring (`Main display is mirrored`, `Display count = / < / >`, `Ignore built-in display`) · USB device · Bluetooth device · app running · app running **and frontmost** · battery charging and/or above a threshold · power adapter connected/disconnected · specific IP address (or range) · Wi-Fi network name · Cisco AnyConnect VPN · specific DNS servers · audio output / headphones in use · specific drive or volume mounted · CPU utilization threshold · system idle time threshold · **Schedule** (time-of-day + weekday range).

Interaction with manual sessions: Triggers are gated by a global `Enable Triggers` box plus a per-Trigger `Enabled` box; a Trigger will not start a session while one is already active; AppleScript `end session` "will not end a Trigger Session"; and after an AppleScript-started session ends, "Trigger sessions will resume … if all criteria for the Trigger to activate are still met."

Sources: [Getting Started With Triggers](https://iffy.freshdesk.com/support/solutions/articles/48000078455-getting-started-with-triggers) ([snapshot](https://web.archive.org/web/20260609082358id_/https://iffy.freshdesk.com/support/solutions/articles/48000078455-getting-started-with-triggers)) · [App Store listing](https://apps.apple.com/us/app/amphetamine/id937984704?mt=12) · `MainMenu.strings` (5.3.2).

---

## 7. Automation

| Channel | Present? | Evidence |
| --- | --- | --- |
| **AppleScript** | **Yes.** `Info.plist` has `NSAppleScriptEnabled = true` and `OSAScriptingDefinition`; `Amphetamine.sdef` defines 22 commands: `start new session` (with `{duration, interval, displaySleepAllowed}`), `end session`, `allow/prevent display sleep`, `allow/prevent screen saver`, `enable/disable closed display mode`, `enable/disable Triggers`, `enable/disable Drive Alive`, and the queries `session is active`, `session time remaining`, `display sleep allowed`, `screen saver allowed`, `closed display mode enabled`, `session is Trigger`, `Triggers are enabled`, `Drive Alive is enabled` (plus the easter egg `give molecule`) | bundle + [AppleScript Documentation](https://iffy.freshdesk.com/support/solutions/articles/48000078223-applescript-documentation) |
| **Shortcuts** | **No.** No `PlugIns` directory, no Intents extension, no `NSUserActivityTypes` in `Info.plist` | 5.3.2 bundle |
| **URL scheme** | **No.** `Info.plist` declares no `CFBundleURLTypes` | 5.3.2 bundle |
| Third-party glue | An official article covers driving Amphetamine from **Alfred** — i.e. via AppleScript | [Controlling Amphetamine with Alfred](https://iffy.freshdesk.com/support/solutions/articles/48000078267-controlling-amphetamine-with-alfred) |

`session time remaining` sentinel values are a neat model for Medusa's End conditions: `0` = infinite, `-1` = Trigger-based, `-2` = app-based or until-a-time, `-3` = no active session.

→ Map's "AppleScript / Shortcuts / URL-scheme automation — out of scope" loses nothing Amphetamine ships except AppleScript.

---

## 8. Safety and honesty copy (verbatim, for precedent)

Amphetamine's own words, from `en.lproj/Localizable.strings` in the 5.3.2 bundle unless noted. This is the tone Medusa should steal.

**On lid-closed limits — the three-bullet warning shown for Closed-Display Mode:**

> **• Power State** — Closed-display mode sessions may fail if your Mac is reconnected to an external power source/adapter during the session. This issue does not affect all Macs and Amphetamine is unable to detect whether the session has actually failed.
>
> **• Overheating and Battery Drain** — Your Mac could easily overheat inside of a bag/case or its battery could drain completely if you forget that a Closed-Display Mode session is active. Please consider enabling Closed-Display Mode warnings in Settings → Notifications.
>
> **• Amphetamine Enhancer Fail-Safe** — If Amphetamine crashes during a Closed-Display Mode session, your Mac may be unable to return to normal sleeping behavior until you relaunch Amphetamine or you reboot your Mac. It is highly recommended that you install Amphetamine Enhancer as a fail-safe.

**On the requirements it overrides:**

> Generally, an external display, keyboard, mouse, and power adapter must all be connected to your Mac for Closed-Display Mode to be enabled. Amphetamine can override these requirements temporarily and prevent your Mac from sleeping when its display is closed. The checkbox will be disabled if your Mac does not support this feature.

**On a failure it cannot fix** — the whole article is an unusually honest retraction:

> At the time of version 5.2's release, it was my understanding that all Macs were affected by this issue. … It is now clear that not all Macs are affected by this issue, however, and I have not been able to find a reliable way to identify which Macs are affected. Unfortunately, in the event that your Mac is affected by this issue, there does not appear to be a way for Amphetamine to avoid or otherwise prevent the failed closed-display mode from occurring. Once the closed-display mode session fails, your Mac will immediately sleep and Amphetamine is blocked from executing any additional code to address the failure or recover the failed session.
> — [About Failed Closed-Display Mode Sessions](https://iffy.freshdesk.com/support/solutions/articles/48001180528-about-failed-closed-display-mode-sessions) ([snapshot](https://web.archive.org/web/20260405023808id_/https://iffy.freshdesk.com/support/solutions/articles/48001180528-about-failed-closed-display-mode-sessions))

**On a stuck assertion after a crash:**

> An Amphetamine session is not currently active, but Power Protect is enabled and is keeping your Mac awake. This can lead to unexpected battery drain and/or overheating, especially in Closed-Display Mode. … This issue may have been caused by quitting Amphetamine during a Closed-Display Mode enabled session, due to a Amphetamine crashing during a Closed-Display Mode enabled session, or by someone manually disabling sleep on your Mac.

Directly relevant to Medusa's decision 15 (IOKit assertion **timeout** as belt-and-braces): this is exactly the failure mode Amphetamine ships an *alert* for and Medusa proposes to make structurally impossible.

**On the battery guard:**

> **• End Session if Battery Charge is Below …** Check this box if you want Amphetamine to automatically end non-Trigger sessions when your Mac's battery falls below the threshold set using the slider. Move the slider all the way to the right to end sessions any time the power adapter is not connected.
> **• Prompt Before Ending a Session** Check this box if you want to be prompted before Amphetamine automatically ends a session due to a low battery charge. You can choose to continue the session, ignoring your Mac's battery charge, if desired.
> **• Ignore Charge if Power Adapter is Connected** …
> Note that these settings only affect non-Trigger sessions.

Notification bodies: `Your Mac's battery is below %@.` · `Battery charge is below %li%%` · `Battery is not connected to power adapter` · and the reassuring close, `Your Mac will sleep on its normal schedule`.

**On the marketing framing of lid-closed** — the App Store screenshot caption is itself a safety line: *"Keep your Mac awake while its display is closed. Use an optional alarm so you won't forget it's awake."*

---

## Defaults that argue against a charting decision

**Decision 9 — Battery guard "default on at ≤ 10 %".** The threshold is right; the default is not. Amphetamine ships `End Session if Battery Charge is Below …` **unchecked**, with the slider parked at **10 %** (`End Session On Low Battery = 0`, `Low Battery Percent = 10`). So "10 %" is genuine Amphetamine parity, but "on by default" is a Medusa divergence and should be recorded as a deliberate choice, not as parity. Two sub-options Medusa currently drops are also worth a second look: *Prompt before ending* (Amphetamine lets you keep going and ignore the charge) and *Start a new session if reconnected*.

**Decision 10 — notifications on by default, with an "Ending in 5 minutes" + Extend nudge.** This is the decision the audit hits hardest. (a) Amphetamine has **no ending-soon warning of any kind** — no string, no preference key. (b) Amphetamine **deleted** manual session start/end notifications in v4 on the explicit reasoning that "Manual session start/end requires you to take some action" and the menu-bar icon already changes state. (c) What it *does* default **on** is notifications for sessions the user did **not** start by hand (Trigger/scheduled auto-start and auto-end). The defensible parity-shaped position is: notify by default only when a Session ends for a reason the user did not choose (battery guard, deadline passed while away), and treat the ending-soon nudge as a Medusa original that must earn its default rather than inherit one. Amphetamine's nearest feature, periodic **Session Reminders**, ships **off** at a 60-minute interval.

**Decision 13 — "editable presets, default quick-start Indefinitely".** Half parity, half invention. *Indefinitely* is confirmed verbatim ("indefinitely by default"). But Amphetamine's preset list is **not editable**: it is a fixed 5→60 minutes in 5-minute steps plus 1→12 and 24 hours — 24 fixed choices against Medusa's 6 editable ones, and it reaches **24 h** where Medusa stops at 8 h. Ad-hoc times come from a one-off "Other Time/Until…" sheet, not from editing the list. So the map's "(Amphetamine parity, pending research 02)" annotation on decision 13 should be narrowed to the Default Duration only, and "editable Presets" re-justified on Medusa's own terms (or replaced by Amphetamine's cheaper fixed-ladder-plus-custom model).

**Decision 6 — "deadlines, not stopwatches", hardcoded.** Amphetamine makes this a user-visible preference — `End Time Calculation: Use timer / Use system clock` — with a worked example in the help text, and pairs it with `End session when Mac is forced to sleep` (default off). Enough users evidently wanted the *stopwatch* reading that the developer shipped both. Medusa's hardcoded deadline is still the better default, but the map should expect the "my 3-hour session lost an hour while the lid was shut" complaint and answer it in copy.

**Decision 12 — hotkey default unassigned.** *Supported.* Amphetamine ships **six** hot keys and **none** of them assigned.

**Decision 11 — countdown in the menu bar, default off; session header on.** *Supported* on both halves (`Show Session Time In Status Bar = 0`, `Show Session Details In Menu = 1`). One free idea: Amphetamine's default click mapping is **left click = menu, right/⌃ click = quick-start with the Default Duration**, which gives one-click keep-awake without touching a submenu.

**Decision 4 — Session default Awake level = Display awake.** *Supported.* `Allow display sleep` ships unchecked, and the docs describe exactly Medusa's two levels: "one [assertion] to keep your display awake (optional), and one to keep your system awake (required)".

**Decision 5 — "while an app is running" deferred to ticket 05.** Amphetamine ships it, but sandboxing means it can only see **apps**, not processes; seeing `claude`, `codex` or `xcodebuild` requires the separate, unsandboxed **Amphetamine Enhancer** helper. Medusa is not sandboxed and not on the App Store, so this is the one place where a v1 clone can be strictly better than the original with no helper app.

---

## Sources

**First-party, live**
- Mac App Store listing, Amphetamine 5.3.2 by William Gustafson (full description, trigger list, "What Else Does Amphetamine Do?", release notes / Power Protect): https://apps.apple.com/us/app/amphetamine/id937984704?mt=12 — description and 5.3.2 release notes read via the public iTunes lookup endpoint `https://itunes.apple.com/lookup?id=937984704`; screenshots read at full resolution from the same payload.
- Amphetamine Enhancer README (fail-safe, all-running-processes, sandboxing rationale, MIT): https://github.com/x74353/Amphetamine-Enhancer

**First-party, shipped app (Amphetamine 5.3.2, `/Applications/Amphetamine.app`)**
- `Contents/Info.plist` — `NSAppleScriptEnabled`, `LSUIElement`, absence of `CFBundleURLTypes`; `Contents/PlugIns` absent
- `Contents/Resources/Amphetamine.sdef` — the 22 AppleScript commands
- `Contents/Resources/en.lproj/Localizable.strings`, `.../MainMenu.strings` — all verbatim UI copy, help text, option labels, icon and sound names, duration ladder
- `Contents/Frameworks/MASShortcut.framework` — hot-key recorder
- `~/Library/Containers/com.if.Amphetamine/Data/Library/Preferences/com.if.Amphetamine.plist` — the ⚠️ observed values

**First-party support portal (now login-gated; read via Wayback)**
- Amphetamine 101 — https://iffy.freshdesk.com/support/solutions/articles/48000078454-amphetamine-101 (snapshot 2026-06-09)
- AppleScript Documentation — .../48000078223-applescript-documentation (snapshot 2026-06-09)
- Getting Started With Triggers — .../48000078455-getting-started-with-triggers (snapshot 2026-06-09)
- Notifications in Amphetamine — .../48000078311-notifications-in-amphetamine (snapshot 2026-04-14)
- Amphetamine Closed-Display Mode — .../48001077199-amphetamine-closed-display-mode (snapshot 2026-04-21)
- About Failed Closed-Display Mode Sessions — .../48001180528-about-failed-closed-display-mode-sessions (snapshot 2026-04-05)
- Mac Still Sleeps After Closing Display/Lid — .../48000078421-mac-still-sleeps-after-closing-display-lid (snapshot 2026-04-05)
- Amphetamine Does Not Keep My Mac Awake — .../48000078314--amphetamine-does-not-keep-my-mac-awake (snapshot 2026-06-09)
- My Mac's Display Is Not Sleeping — .../48000078418-my-mac-s-display-is-not-sleeping (snapshot 2026-06-09)
- How Is Amphetamine Different From Other Keep-Awake Apps? — .../48000078312-how-is-amphetamine-different-from-other-keep-awake-apps- (snapshot 2026-06-02)
- Screen Locks When Accessing Mac Remotely — .../48000144720-screen-locks-when-accessing-mac-remotely (snapshot 2026-04-05)
- About Amphetamine Enhancer — .../48000960521-about-amphetamine-enhancer (snapshot 2026-06-13)
- Legacy Menu Bar Images — .../48000078310-legacy-menu-bar-images (snapshot 2026-05-18)

**Secondary sources: none used.** No forum, Reddit or MacRumors claim appears in this file.

**Dead ends, for the record:** `https://iffy.app/amphetamine/` returns 404 and `iffy.app` now serves an unrelated site; `iffy.freshdesk.com` answers every article with "Portal is currently not accessible"; `raw.githubusercontent.com/x74353/Amphetamine-Enhancer/master/README.md` 404s (the README is served through the GitHub API instead).
