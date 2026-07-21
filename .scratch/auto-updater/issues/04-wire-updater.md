# Wire the updater into the app

Type: task
Status: resolved
Blocked by: 01, 02, 03

## Question

Implement the in-app updater per the research findings and the map's UX defaults:

- Add the Sparkle 2 SPM dependency (pinned per ticket 01) and instantiate the updater controller programmatically in the nib-less AppKit app.
- "Check for Updates…" item in the menu-bar menu; Updates row in Settings → General (auto-check toggle; anything further per the fog note on the map).
- UX defaults: Sparkle consent prompt, daily background checks, prompt-before-install with release notes.
- **Lock-state guard** per ticket 02: the updater is inert while the shield is up — no prompts, no installs, no relaunch under lock.
- Dev-build behavior per ticket 02 (likely: updater disabled in ad-hoc builds).
- `build-app.sh` grows framework embedding + rpath + nested signing per ticket 01, keeping ad-hoc dev builds working.
- Verify locally: app builds, launches, `--self-test` still passes, updater UI reachable, no TCC re-prompt after a rebuild with stable identity.

## Answer

Done 2026-07-21 (goal-override execution):

- **`Sources/Medusa/Updater.swift`** — `UpdaterController` owns `SPUStandardUpdaterController(startingUpdater: false, …)` and starts it only when `updatesSupported`: the bundle is Developer ID-signed (runtime `SecStaticCodeCheckValidity` against the DevID leaf OID `1.2.840.113635.100.6.1.13`) or `MEDUSA_UPDATER_DEV=1`. The four lock gates from research 02 are implemented (`mayPerform` veto, gentle-reminder deferral with re-present on unlock, install-on-quit hold, relaunch refusal). `MEDUSA_FEED_URL` override honored only under the dev flag. Extra: under the dev flag a silently-downloaded update installs immediately (`immediateInstallationBlock`) — the e2e harness can't click "Install and Relaunch"; production paths unaffected.
- **AppDelegate** wires `isLocked` from `LockController`, calls `lockDidRelease()` on unlock, and attaches the menu item only in supported builds. **MenuBarController.attachUpdater** targets the Sparkle controller directly (free menu validation). **Settings → General** gains an Updates section (auto-check toggle + version + Check Now/last-checked via a KVO-bridged view model); dev builds show "Automatic updates are available in released builds only."
- **Verified**: clean `swift build`; `codesign --verify --deep --strict` passes on the assembled bundle; `--self-test` full PASS; the [end-to-end proof](07-local-e2e-proof.md) ran the whole loop on this machine.

## Comments
