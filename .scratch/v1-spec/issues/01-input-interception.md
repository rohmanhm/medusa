# Input interception & permissions

Type: research
Status: resolved

## Question

How does system-wide input interception work on macOS 15+, and what does it demand of the app?

- CGEventTap specifics: tap location (`cghidEventTap` vs session), active-filter vs listen-only, event mask for keyboard + mouse + trackpad, swallowing events by returning null.
- Which TCC permission this actually requires — Accessibility vs Input Monitoring — and how an app detects/queries grant state.
- What *cannot* be intercepted: ⌘⌥⎋ (Force Quit), power/Touch ID button, Globe/Fn, media keys, secure event input, Touch Bar. Enumerate the escape hatches the OS reserves.
- System behavior when a tap is slow/unresponsive (taps get auto-disabled — `kCGEventTapDisabledByTimeout`): exact semantics, re-enable patterns. Feeds the fail-safe ticket.
- Hardened runtime + entitlement constraints; confirm App Sandbox is incompatible with event taps.
- How peer apps (Karabiner-Elements, Hammerspoon, AltTab) structure their tap + permission handling.

Findings file: `.scratch/v1-spec/research/01-input-interception.md`

## Answer

Full findings: [`.scratch/v1-spec/research/01-input-interception.md`](../research/01-input-interception.md)

Medusa must swallow all input, so it needs an **active** `CGEventTap`, not listen-only. Key facts:

- **Tap:** `CGEventTapCreate(kCGSessionEventTap, kCGHeadInsertEventTap, kCGEventTapOptionDefault, mask, …)`, swallow by returning `NULL`. Session tap needs no root; `kCGHIDEventTap` would require running as root. Mask keyboard (keyDown/keyUp/flagsChanged) + all mouse buttons + moved/dragged + scrollWheel (+ `NX_SYSDEFINED` for media keys, best-effort).
- **Permissions:** an active/swallowing tap needs **both Input Monitoring** (`CGRequestListenEventAccess`) **and Accessibility** (`AXIsProcessTrustedWithOptions`). Listen-only would need Input Monitoring alone. No dedicated "is-my-tap-allowed" API — ground truth is `CGEventTapCreate` returning non-NULL and staying enabled (`AXIsProcessTrusted` is stale/buggy on macOS 13+).
- **Cannot block (OS-reserved):** power/Touch ID button (firmware/Secure Enclave, never a CGEvent), anything under **Secure Event Input** (login, FileVault, password fields — TN2150 withholds keys from all taps), ⌘⌥⎋ Force Quit (loginwindow priority), firmware boot combos; Fn/Globe and media keys are only partially catchable.
- **Auto-disable:** slow callbacks trigger `kCGEventTapDisabledByTimeout` (threshold undocumented, seconds-range); also `...ByUserInput` on revoke. Re-enable via `CGEventTapEnable(tap,true)` in-callback **plus** a periodic `CGEventTapIsEnabled` watchdog (the callback isn't always fired, esp. after sleep/wake). Keep the callback trivially fast; **fail open** if the tap can't stay healthy.
- **Packaging:** no entitlement enables taps (pure TCC consent); Hardened Runtime is required for notarization and is fine. **App Sandbox / Mac App Store is a dead end for Medusa** because the required Accessibility grant is unavailable to sandboxed apps — ship Developer ID + notarized, with a stable signature so TCC grants survive updates.
- **Peers:** Hammerspoon is the direct blueprint (session/headInsert/default tap, NULL to swallow, re-enable on both disable events). AltTab shows the permission-polling/restart-on-revoke lifecycle. Karabiner deliberately avoids taps for reliability, seizing the HID device via a root daemon + DriverKit virtual device — heavier, but the fallback if a tap proves too leaky.
