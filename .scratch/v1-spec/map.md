# Map: Medusa v1 spec

Labels: wayfinder:map

## Destination

A build-ready spec (`.scratch/v1-spec/spec.md`) for **Medusa v1**: an open-source macOS utility — system-wide input interception, Touch ID/password unlock, multi-display lock overlays, sleep prevention, global hotkey — shipped as signed & notarized binaries via GitHub Releases + Homebrew cask. The map closes when every decision is locked and the spec is written and reviewed; building v1 happens outside this map.

## Notes

- **GOAL OVERRIDE (2026-07-20)**: plan-only is lifted — the user asked to *implement* v1 until it runs end-to-end on their Mac. Execution now lives in the map. Decision tickets 05/08/09/10/11 resolved inline with recommended defaults; the spike (07) is realized as the actual app rather than throwaway. Ticket 06 (Apple Developer ID) stays deferred — not needed for local ad-hoc-signed testing; only gates public distribution.
- **Build**: Swift 5 language mode, pure AppKit, zero third-party deps, SPM executable assembled into an ad-hoc-signed `.app` by `scripts/build-app.sh`. Target macOS 13+, tested on 26.5.
- ~~**Plan-only map**~~: superseded by the goal override above.
- **Skills**: `/research` for research tickets; `/grilling` + `/domain-modeling` for grilling tickets; `/prototype` for the spike.
- **Tracker**: local markdown per `docs/agents/issue-tracker.md`. Research findings live as files under `.scratch/v1-spec/research/` (not on git branches — repo has no commits yet and auto-commits are forbidden here).
- **Charting decisions** (made while naming the destination, no tickets behind them):
  - Open-source release — no licensing or payments machinery.
  - The full feature set — input lock, Touch ID/password unlock, multi-display overlays, keep-awake, hotkey — is the v1 line.
  - The app is named **Medusa** (this repo).
  - Releases are signed & notarized under an Apple Developer ID.
  - README is the landing page; no marketing site in v1.

## Decisions so far

<!-- one line per closed ticket: gist + link -->

- [Input interception & permissions](issues/01-input-interception.md) — active session-level `CGEventTap` (Hammerspoon as blueprint), swallowing by returning NULL; needs **both** Input Monitoring and Accessibility TCC grants (tap creation itself is the ground truth, not `AXIsProcessTrusted`); App Sandbox/App Store confirmed dead; handle tap auto-disable with in-callback re-enable + watchdog, and **fail open**; power button, Secure Event Input, and ⌘⌥⎋ are OS-reserved escapes nobody can block.
- [Unlocking while input is blocked](issues/02-unlock-under-lock.md) — viable: Touch ID/Watch never traverse the event pipeline, and Secure Event Input routes password typing around all taps; the only gap is mouse clicks — pass mouse events through while `evaluatePolicy` runs (Lockpaw-proven). Use `.deviceOwnerAuthentication`; never gate on `canEvaluatePolicy`. Two empirics left for the spike: dialog z-order vs shield, in-dialog retry counts.
- [Overlays, multi-display & sleep prevention](issues/03-overlay-sleep.md) — one shielding-level window per screen (`canJoinAllSpaces`/`.stationary`), rebuilt on display changes; `PreventUserIdleDisplaySleep` assertion keeps tasks running; overlay stays visible in captures; the lock is an input shield, not an auth boundary.
- [OSS license & repo posture](issues/05-license-posture.md) — **MIT**, contributions-welcome; `LICENSE` + README shipped. (Fork-and-sell risk accepted for adoption.)
- [Core-interaction spike](issues/07-core-spike.md) — realized directly as the shipping app (goal override), not throwaway: `InputTap` + `ShieldController` + `Authenticator` wired in `LockController`. Builds, launches, stable. The two z-order/retry empirics move to the on-machine test.
- [Tech stack & minimum macOS version](issues/08-tech-stack.md) — Swift 5 language mode, **pure AppKit**, **zero third-party deps**, SPM executable → ad-hoc `.app` via `scripts/build-app.sh`; min macOS 13, tested 26.5. Sparkle deferred with distribution.
- [Fail-safe & lockout recovery](issues/09-fail-safe.md) — **fail-open** if tap can't be created; in-callback re-enable on `tapDisabled*` + 1 s watchdog; escape hatches (⌘⌥⎋, power button, SSH kill) documented in README, not fought.
- [Permissions onboarding flow](issues/10-onboarding.md) — `OnboardingWindow`: two-permission explainer, deep-links to the Accessibility + Input Monitoring panes, polls until granted; shown on first run and on any lock attempt while a grant is missing.
- [UX surface](issues/11-ux-surface.md) — menu-bar-only (LSUIElement), ⌘⇧L global hotkey + menu "Lock Now"; lock screen = black field, live clock, "press any key or click to unlock" hint; "first interaction cues auth" unlock model.
- [Signed OSS distribution pipeline](issues/04-distribution.md) — stapled DMG from tag-triggered CI (`notarytool` + ASC API key, ephemeral-keychain P12); self-hosted tap first (homebrew/cask notability thresholds), cask token must be `medusa-app`; Sparkle 2 appcast for updates; AltTab's pipeline is the template.

## Not yet specified

- **VERIFIED END-TO-END (2026-07-20):** permissions granted; `--lock-test` blocked all input across both displays for 5s and auto-released cleanly on the live machine; `--self-test`/`--verify` report PASS (tap create+enable ✅, overlay ✅, power assertion ✅). The core lock/unblock cycle is proven on real hardware.
- **Remaining (human-only):** the Touch ID/password unlock via ⌘⇧L — needs a fingerprint/secret, un-automatable by design. The single empirical left: does the auth dialog render above the shield (dropped to screen-saver level during auth)? Fallback is a one-line level change if not; Force Quit covers the user meanwhile.
- Signed/notarized release + Homebrew `medusa-app` cask + Sparkle 2 appcast — deferred with [Apple Developer ID provisioning](issues/06-developer-id.md); research done, wiring not.
- Testing strategy for system-level behavior (how to CI-test an event tap) — post-v1.

## Out of scope

- Licensing, payments, trials — dropped by the open-source decision.
- Landing page / marketing site — the README is the landing page; revisit post-release if traction warrants.
- Mac App Store distribution — event taps cannot ship sandboxed.
- Extra features (scheduled lock, Apple Watch unlock, etc.) — post-v1 territory.
- Non-macOS platforms.
