# Research: Unlocking while input is blocked

Ticket: `.scratch/v1-spec/issues/02-unlock-under-lock.md`
Date: 2026-07-20

## TL;DR

The risk is real but narrower than feared, and the escape hatch is built into macOS. Three separate input paths matter:

1. **Touch ID is not an input event at all.** Fingerprint data flows sensor → Secure Enclave → `biometrickitd` → `coreauthd`; it never enters the WindowServer event stream, so a CGEvent tap can neither observe nor block it. Touch ID unlock works no matter how aggressive the tap is.
2. **Password typing in the system auth dialog is protected by Secure Event Input.** Apple TN2150 is explicit: while any process has secure input enabled (every system password field does), the OS *stops routing keyboard events through intercept processes entirely* — listen-only and filtering taps alike. Keystrokes are delivered directly to the focused dialog; our tap cannot starve it.
3. **Mouse clicks are NOT protected.** Secure input covers keyboard only. If the tap swallows mouse events, the user cannot click "Use Password…"/"Cancel" in the dialog's Touch ID phase. This is the one genuine starvation risk, and it's why every working peer (e.g. Lockpaw) either leaves mouse events out of the blocking mask or handles clicks inside the tap callback.

Recommended pattern: keep the keyboard/scroll block active during auth (safe), stop swallowing mouse events while `evaluatePolicy` is in flight (the shield overlay absorbs stray clicks), use `.deviceOwnerAuthentication`, and handle `tapDisabledByTimeout`/`tapDisabledByUserInput` by re-enabling the tap. Several details (dialog vs. shield window z-order, per-dialog retry counts) can only be confirmed empirically — experiment plan in §6.

---

## 1. Does the `LAContext` dialog receive input independently of a session-level event tap?

**Partially — and the parts that bypass the tap are exactly the parts that matter.**

### The dialog is a separate process, but that alone buys nothing

On modern macOS the LocalAuthentication dialog is presented by the `coreauthd` daemon and its per-user UI agent `coreautha` (verified locally: `/System/Library/Frameworks/LocalAuthentication.framework/Support/` contains `coreauthd` and `coreautha.bundle`; both are running on this machine). SecurityAgent (`/System/Library/CoreServices/SecurityAgentPlugins/`) handles the older Authorization Services dialogs. Either way it is not our process — but a `kCGSessionEventTap` filtering tap sits in the WindowServer *before per-application routing*, so ordinary keyboard/mouse events destined for `coreautha` flow through our tap like everyone else's and **would** be swallowed. "Separate process" is not the bypass mechanism.

### The actual bypass #1: Touch ID isn't a CGEvent

CGEvent taps only see Quartz event types (key, mouse, scroll, tablet — see the `CGEventType` enum). A fingerprint match happens in the Secure Enclave and is reported to `coreauthd` via `biometrickitd`; nothing traverses the event pipeline. A tap swallowing 100% of HID events cannot interfere with Touch ID. (Corroborated by shipped OSS: Lockpaw blocks all keyboard/scroll/tablet events with a filtering session tap and Touch ID unlock via `LAContext` works — [sorkila/lockpaw](https://github.com/sorkila/lockpaw).)

### The actual bypass #2: Secure Event Input reroutes keyboard around taps

Apple Technical Note TN2150 ("Secure Event Input") documents the mechanism:

> "The fix for this problem is to stop passing keyboard events to any intercept process whenever any process has enabled secure event input, whether that process is in the foreground or background."

and lists event taps ("installation of an event tap as defined in CoreGraphics/CGEvent.h") as one of the intercept mechanisms this applies to ([TN2150](https://developer.apple.com/library/archive/technotes/tn2150/_index.html)). System password fields (`NSSecureTextField`, the Carbon password controls) enable secure input automatically ([EnableSecureEventInput discussion, CarbonEventsCore.h in the macOS SDK](https://developer.apple.com/documentation/carbon/1462240-enablesecureeventinput)): "keyboard input will only go to the application with keyboard focus, and will not be echoed to other applications."

The Karabiner-Elements author's reference deck states it as a hard limitation: CGEventTapCreate "**cannot receive Secure Keyboard Entry**" (only a root IOHIDDevice reader can) — [All about macOS event observation](https://docs.google.com/presentation/d/1nEaiPUduh1vjks0rDVRTcJaEULbSWWh1tVdG2HF_XSU/htmlpresent). The entire macro/expansion ecosystem confirms taps go blind — not merely "can't log," but events are simply never routed through them: [Keyboard Maestro wiki](https://wiki.keyboardmaestro.com/assistance/Secure_Input_Problem) ("macOS will not let applications watch the keyboard when you are in a password field"), [1Password community](https://www.1password.community/1password-at-work-58/secure-input-blocking-other-apps-event-taps-25015), [TextExpander](https://textexpander.com/secure-input), [ghostty #1325](https://github.com/ghostty-org/ghostty/issues/1325).

**Consequence:** when the LA dialog's password field has focus, our filtering tap does not receive those keystrokes at all — it cannot swallow what it never sees. The password fallback types fine under a total keyboard block. This also means: filtering-vs-listening makes no difference; both are skipped.

Side effect to handle: when secure input engages (and in other situations), the system may disable keyboard taps and deliver `kCGEventTapDisabledByUserInput` / `kCGEventTapDisabledByTimeout` to the callback ([CGEventType.tapDisabledByUserInput](https://developer.apple.com/documentation/coregraphics/cgeventtype/tapdisabledbyuserinput)). The callback must respond with `CGEvent.tapEnable(tap:enable:true)` or the block silently dies — the exact bug ghostty hit ([discussion #11819](https://github.com/ghostty-org/ghostty/discussions/11819)). Lockpaw does this re-enable synchronously in the callback.

### The gap: mouse events

TN2150 and secure input cover **keyboard only**. Buttons in the dialog ("Use Password…", "Cancel", and the Touch ID-phase UI generally) need clicks, and clicks DO traverse our tap. If Medusa's mask swallows mouse buttons during auth, the user can Touch-ID their way out but cannot reach the password fallback by mouse. On a Touch ID Mac whose sensor fails (wet fingers, lockout), that's a lockout-from-your-own-lock — the nightmare scenario.

**Verdict on the ticket's headline question:** the dialog does *not* generically receive input "independently of the tap." Touch ID bypasses it (always), secure-input keyboard bypasses it (whenever the password field is focused), mouse never bypasses it. Design for the mouse gap.

## 2. Patterns that work

Ranked; they compose.

1. **Leave mouse out of the blocking mask entirely (Lockpaw's pattern).** Lockpaw taps `.cgSessionEventTap` / `.headInsertEventTap` / `.defaultTap` with mask `keyDown, keyUp, flagsChanged, scrollWheel, tabletPointer, tabletProximity`, returns `nil` to swallow, and simply never includes mouse events ([InputBlocker.swift](https://github.com/sorkila/lockpaw)). Stray clicks land on the full-screen shield window (its own app), so "mouse works" costs nothing: there is nothing under the cursor except the overlay. Clicks on the LA dialog work; keyboard/scroll stay dead. Simplest and proven. Downside: mouse-click blocking is part of Medusa's spec ("blocks… mouse"), so pure pass-through may not satisfy the product.
2. **State-gated mask: swallow mouse while locked, pass it while auth is in flight.** Keep one filtering tap; the callback checks an atomic `authInProgress` flag and returns the event unmodified for mouse types when set. Re-arm on `userCancel`/failure. This preserves full click blocking except during the seconds a dialog is up — and during those seconds the shield window still covers every display. Recommended for Medusa.
3. **Temporarily `CGEventTapEnable(tap, false)` around `evaluatePolicy`.** Coarser version of (2): disable the whole tap, make the shield window key (`canBecomeKey = true` override on the borderless window) so stray keystrokes land harmlessly in our app, re-enable on failure. Slightly larger exposure window (keyboard live too) but dead simple and used informally by several utilities. Fine as v1 fallback if (2) gets fiddly.
4. **Hit-test clicks inside the tap callback (allowlist by region/target).** The callback gets event coordinates; pass through only events within the auth dialog's frame or our own unlock-button rect, swallow the rest. This is how a clickable on-screen unlock button can coexist with a total click block. Works, but finding the dialog's frame from another process needs CGWindowList queries — more moving parts.
5. **Own the whole unlock UI (no system dialog for fallback).** Embed `LAAuthenticationView` (macOS 12+, `LocalAuthenticationEmbeddedUI.framework`) in the shield window for Touch ID ([docs](https://developer.apple.com/documentation/localauthenticationembeddedui/laauthenticationview)), plus our own `NSSecureTextField` for password — which *itself* enables secure input, so typing into it bypasses our own keyboard tap — validated via OpenDirectory: `ODRecord.verifyPassword(_:)` against the local node ([docs](https://developer.apple.com/documentation/opendirectory/odrecord/verifypassword(_:)), Apple DTS-endorsed approach in [forums thread 117924](https://developer.apple.com/forums/thread/117924); use `kODNodeTypeAuthentication`). No system dialog, no mouse gap, full visual control — this is the macOS analog of how X11 lockers (xscreensaver, i3lock) draw their own field and verify via PAM. Cost: we own rate limiting, lockout UX, and password-verification code paths. Good v2 target, overkill for v1.

**Anti-pattern:** IOKit device seizure (`IOHIDManager` with `kIOHIDOptionsTypeSeizeDevice`, as KT-Locker dabbles in) blocks input *below* the WindowServer — which also starves the secure-input path and the auth dialog itself. The CGEvent tap is the right layer precisely because macOS routes secure keyboard input around it.

## 3. `.deviceOwnerAuthentication` vs `.deviceOwnerAuthenticationWithBiometrics`

([deviceOwnerAuthentication](https://developer.apple.com/documentation/localauthentication/lapolicy/deviceownerauthentication), [deviceOwnerAuthenticationWithBiometrics](https://developer.apple.com/documentation/localauthentication/lapolicy/deviceownerauthenticationwithbiometrics), [LAError.biometryLockout](https://developer.apple.com/documentation/localauthentication/laerror/code/2867589-biometrylockout))

| | `.deviceOwnerAuthentication` | `.deviceOwnerAuthenticationWithBiometrics` |
|---|---|---|
| Methods (macOS) | Touch ID, **Apple Watch (tried in parallel)**, user's password | Touch ID only |
| Password fallback | Built-in: fallback button reverts the dialog to password entry, system-handled | None — fallback button fails evaluation with `LAError.userFallback`; the app must supply its own mechanism |
| No-biometry Macs | Works (goes straight to password/Watch) | `canEvaluatePolicy` fails (`biometryNotAvailable`/`notEnrolled`) |
| Lockout | Password path always available | Fails with `biometryLockout` after too many consecutive failures |

Key doc quotes: "If biometry is available, enrolled, and not disabled, the system uses that first. In macOS, the system simultaneously looks for a nearby, paired Apple Watch running watchOS 6 or later… When these options aren't available, the system prompts the user for the device passcode or user's password." And for biometrics-only: "Both Touch ID and Face ID authentication are disabled system-wide after too many consecutive unsuccessful attempts, even when the attempts span multiple evaluation calls. When this happens, the system requires the user to enter the device passcode to reenable biometry."

Retry/lockout numbers: Apple's docs deliberately say "too many." Community + support consensus is **5 consecutive failed Touch ID attempts → system-wide biometry lockout, password required to re-enable** ([Apple dev forums 67595](https://developer.apple.com/forums/thread/67595), [Apple Support 102356](https://support.apple.com/en-us/102356)). Within a single dialog, macOS gives a small number of tries (commonly observed: 3) before pushing the fallback button/password UI — the exact in-dialog count is undocumented; verify empirically (§6). iOS-style note in the docs: passcode authentication gets progressively increasing delays after repeated failures; whether the macOS *password* sheet throttles similarly is undocumented — peers add their own rate limiting anyway (Lockpaw: 30 s cooldown after 3 failed unlock attempts), which Medusa should copy.

**Recommendation:** `.deviceOwnerAuthentication` for v1. Free password fallback (covers non-Touch ID Macs and biometry lockout), free Apple Watch support, and the fallback dialog is exactly the secure-input-protected system UI that works under our keyboard block. Handle `userCancel`, `authenticationFailed`, `biometryLockout`, `systemCancel`. Also set `localizedCancelTitle`/`localizedFallbackTitle` for clarity.

## 4. Edge cases

- **Macs without Touch ID** (pre-2016 laptops, most desktops without a Touch ID Magic Keyboard): `.deviceOwnerAuthentication` shows the password dialog immediately. The `NSSecureTextField` engages secure input → typing works under the tap; Return submits and Esc cancels, and during secure input those keys go directly to the focused dialog, not through our tap. Expected fully functional even with mouse blocked — verify (§6).
- **Clamshell mode:** the built-in sensor is physically unreachable with the lid closed. A Magic Keyboard with Touch ID covers this — but it pairs biometrics only with **Apple silicon Macs** ([Apple Support 102356](https://support.apple.com/en-us/102356)). Known LA bug: with the lid closed, `canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics)` returns `false` even while Magic Keyboard Touch ID demonstrably works for OS prompts — Apple DTS (Quinn) confirmed: "I think it's safe to label the LAContext behaviour a bug" ([forums thread 711838](https://developer.apple.com/forums/thread/711838)). **Do not gate the unlock UX on `canEvaluatePolicy`** — always evaluate `.deviceOwnerAuthentication` and let the system route to whatever works (Touch ID, Watch, or password).
- **Apple Watch:** included automatically in `.deviceOwnerAuthentication` (paired, unlocked, nearby, watchOS 6+; user approves by double-clicking the side button). Like Touch ID it involves no CGEvents, so it is immune to the tap. Dedicated policies exist (`.deviceOwnerAuthenticationWithBiometricsOrWatch`, `…WithWatch`, macOS 10.15+) but aren't needed for v1.
- **After reboot / biometry lockout:** macOS requires the account password before Touch ID becomes available (standard SEP policy, [Apple Support 102356](https://support.apple.com/en-us/102356)); the same `.deviceOwnerAuthentication` password path covers it.
- **Tap lifecycle:** handle `tapDisabledByTimeout`/`tapDisabledByUserInput` by re-enabling; recreate the tap across fast-user-switch (`NSWorkspace.sessionDidResignActive/BecomeActive`) — while another user's session is active our session tap receives nothing anyway (ghostty discussions [#11819](https://github.com/ghostty-org/ghostty/discussions/11819), [#11390](https://github.com/ghostty-org/ghostty/discussions/11390)).
- **Permissions:** a `.defaultTap` (filtering) keyboard tap requires Accessibility TCC approval; Input Monitoring appears on macOS 10.15+ for listen-style access ([Karabiner deck](https://docs.google.com/presentation/d/1nEaiPUduh1vjks0rDVRTcJaEULbSWWh1tVdG2HF_XSU/htmlpresent), [HackTricks overview](https://hacktricks.wiki/en/macos-hardening/macos-security-and-privilege-escalation/macos-security-protections/macos-input-monitoring-screen-capture-accessibility.html)). Covered further in the distribution ticket.

## 5. How peers handle it

- **Lockpaw** ([sorkila/lockpaw](https://github.com/sorkila/lockpaw)) — closest OSS analog, and the strongest empirical evidence available: session-level filtering tap (`.headInsertEventTap`, `.defaultTap`) swallowing keyboard/scroll/tablet, **mouse deliberately excluded** so overlay buttons and the LA dialog stay clickable; hotkey chord detected inside the callback; re-enables on both tap-disabled events; `LAContext.evaluatePolicy(.deviceOwnerAuthentication)` with Touch ID + password fallback working while the keyboard block is active; 3-failures → 30 s cooldown; shield at `CGShieldingWindowLevel()`; explicitly scoped as "a visual privacy tool, not a security boundary" (synthetic events via AppleScript/AX are not blocked).
- **Catlock** ([ehamiter/Catlock](https://github.com/ehamiter/Catlock)): blocks keyboard *and* mouse (moves, clicks, drags, scroll) and therefore never relies on clicks to unlock — key-chord unlock detected in the callback (Esc+Delete), an Fn+Esc failsafe, and a 10-minute auto-unlock timer. The "block everything, unlock by chord only" alternative — worth stealing the failsafe idea regardless of pattern chosen.
- **keylock** ([kfv/keylock](https://github.com/kfv/keylock)), **KT-Locker** ([MichalGow/KT-Locker](https://github.com/MichalGow/KT-Locker)): same CGEventTap approach for cleaning-mode locks; KT-Locker additionally pokes at IOHIDManager (see anti-pattern note in §2).
- **X11 lockers** (xscreensaver, i3lock): grab input server-side and draw their own password field verified via PAM — the architectural ancestor of pattern 5 (`NSSecureTextField` + `ODRecord.verifyPassword`).

## 6. What can only be confirmed empirically

Honesty section: everything in §1 rests on Apple's documented secure-input semantics plus one shipped OSS app. Before building on it, run this spike (½ day, needs a Touch ID Mac + one non-Touch ID Mac or lid-closed test):

Harness: minimal app with (a) full-screen borderless shield window at `CGShieldingWindowLevel()` with `canBecomeKey`, (b) a filtering session tap with a runtime-toggleable mask, (c) a button/hotkey calling `evaluatePolicy(.deviceOwnerAuthentication)`, (d) logging of every callback event type plus `IsSecureEventInputEnabled()` polling.

1. **Z-order:** does the `coreautha` dialog render *above* the shield-level window? (Lockpaw implies yes; not documented anywhere.) If not, drop the overlay to `.screenSaver` level during auth or use `LAAuthenticationView`.
2. **Password typing under full keyboard block:** with keyboard mask active, click "Use Password…" and type — expect keystrokes to reach the field (tap log should show *no* key events while `IsSecureEventInputEnabled()` is true).
3. **Secure-input window:** is secure input active for the dialog's whole lifetime or only while the password field has focus (does Esc work during the Touch ID phase under the block)?
4. **Mouse starvation:** repeat with mouse buttons in the mask — confirm the fallback button becomes unclickable (validates the whole §2 design).
5. **`tapDisabledByUserInput`:** confirm whether it fires when secure input engages, and that re-enabling is harmless.
6. **Retry counts:** measure in-dialog Touch ID attempts before fallback, and confirm 5-consecutive-failure biometry lockout + recovery via password.
7. **Clamshell:** with a Touch ID Magic Keyboard, confirm `evaluatePolicy` (not `canEvaluatePolicy`) routes correctly lid-closed.
8. **`LAAuthenticationView`:** check what its password fallback does (embedded vs. spawning the standard alert — docs only say a standard alert appears when the view isn't attached).

## Sources

- [Apple TN2150 — Secure Event Input](https://developer.apple.com/library/archive/technotes/tn2150/_index.html)
- [EnableSecureEventInput — Apple docs](https://developer.apple.com/documentation/carbon/1462240-enablesecureeventinput) (+ discussion text in `CarbonEventsCore.h`, macOS SDK)
- [CGEventTapCreate](https://developer.apple.com/documentation/coregraphics/1454426-cgeventtapcreate), [CGEventType.tapDisabledByUserInput](https://developer.apple.com/documentation/coregraphics/cgeventtype/tapdisabledbyuserinput)
- [All about macOS event observation — Karabiner-Elements author](https://docs.google.com/presentation/d/1nEaiPUduh1vjks0rDVRTcJaEULbSWWh1tVdG2HF_XSU/htmlpresent)
- [Keyboard Maestro wiki — Secure Input Problem](https://wiki.keyboardmaestro.com/assistance/Secure_Input_Problem) · [1Password community](https://www.1password.community/1password-at-work-58/secure-input-blocking-other-apps-event-taps-25015) · [TextExpander — Secure Input](https://textexpander.com/secure-input) · [ghostty #1325](https://github.com/ghostty-org/ghostty/issues/1325) · [ghostty discussion #11819](https://github.com/ghostty-org/ghostty/discussions/11819)
- [LAPolicy.deviceOwnerAuthentication](https://developer.apple.com/documentation/localauthentication/lapolicy/deviceownerauthentication) · [LAPolicy.deviceOwnerAuthenticationWithBiometrics](https://developer.apple.com/documentation/localauthentication/lapolicy/deviceownerauthenticationwithbiometrics) · [LAError.biometryLockout](https://developer.apple.com/documentation/localauthentication/laerror/code/2867589-biometrylockout)
- [Apple Support 102356 — If Touch ID isn't working on Mac](https://support.apple.com/en-us/102356) · [Apple dev forums 67595 — lockout after 5 consecutive failures](https://developer.apple.com/forums/thread/67595) · [Apple dev forums 711838 — clamshell canEvaluatePolicy bug (DTS-confirmed)](https://developer.apple.com/forums/thread/711838)
- [LAAuthenticationView (LocalAuthenticationEmbeddedUI)](https://developer.apple.com/documentation/localauthenticationembeddedui/laauthenticationview)
- [ODRecord.verifyPassword](https://developer.apple.com/documentation/opendirectory/odrecord/verifypassword(_:)) · [Apple dev forums 117924 — verifying a local user's password](https://developer.apple.com/forums/thread/117924)
- Peers: [sorkila/lockpaw](https://github.com/sorkila/lockpaw) · [ehamiter/Catlock](https://github.com/ehamiter/Catlock) · [kfv/keylock](https://github.com/kfv/keylock) · [MichalGow/KT-Locker](https://github.com/MichalGow/KT-Locker)
- [HackTricks — macOS Input Monitoring / Accessibility](https://hacktricks.wiki/en/macos-hardening/macos-security-and-privilege-escalation/macos-security-protections/macos-input-monitoring-screen-capture-accessibility.html)
