# Spec: Medusa auto-updater (Sparkle 2)

Status: ready-to-build
Sources: [map](map.md) charting decisions + research [01-sparkle-integration](research/01-sparkle-integration.md) / [02-update-safety](research/02-update-safety.md). Where this spec and the research disagree, the research (with citations) wins.

## What ships

Medusa gains a full in-app updater: a background daily check and a "Check for Updates…" menu item; when a new release exists the user is prompted with release notes and can download, install, and relaunch without leaving the app. Powered by **Sparkle 2.9.4** — Medusa's first and only third-party dependency (supersedes the v1 zero-deps rule, by charting decision).

## UX (peer-standard defaults, locked at charting)

- **Consent**: Sparkle's built-in prompt on second launch asks whether to enable automatic checks. No custom UI. (`SUEnableAutomaticChecks` stays unset.)
- **Cadence**: daily (`SUScheduledCheckInterval` unset ⇒ 86400).
- **Install flow**: prompt-before-install with release notes (`SUAutomaticallyUpdate` unset ⇒ NO); user clicks "Install and Relaunch".
- **Surfaces**: "Check for Updates…" `NSMenuItem` in the menu-bar menu (target = `SPUStandardUpdaterController`, action = `checkForUpdates(_:)` — enabled-state validation comes free); Settings → General grows an **Updates** section: auto-check toggle (KVO-bound to `updater.automaticallyChecksForUpdates`), "Check Now" button (enabled via KVO `canCheckForUpdates`), last-checked caption. In non-release builds the section shows "Updates are available in released builds only" and the menu item is omitted.
- **Release notes** in the prompt: `<sparkle:releaseNotesLink>` → the GitHub release page for the tag. Rendering quality gets eyeballed at the first real update (ticket 06); fallback documented there is an embedded `<description>`.

## Safety invariants (from research 02)

1. **Inert while locked** — four Sparkle layers, all keyed on `LockController.isLocked`:
   - `updater(_:mayPerform:)` throws while locked (vetoes scheduled + manual checks + probes);
   - `standardUserDriverShouldHandleShowingScheduledUpdate(_:andInImmediateFocus:)` returns `false` while locked (defers the alert; sets a flag), with `supportsGentleScheduledUpdateReminders = true`;
   - `updater(_:willInstallUpdateOnQuit:immediateInstallationBlock:)` holds the handler while locked;
   - `updaterShouldRelaunchApplication` returns `false` while locked (backstop).
   On unlock, a deferred scheduled update re-presents via `updater.checkForUpdates()`.
2. **Never in dev builds** — construct with `startingUpdater: false`; call `startUpdater()` only when the running bundle is **Developer ID-signed** (checked at runtime via `SecStaticCodeCheckValidity` against `anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13]`) or when `MEDUSA_UPDATER_DEV=1` (the e2e-test hook). Rationale: Sparkle would happily install a DevID release over an ad-hoc build (EdDSA branch of its validator) and the TCC grants would churn — the guard has to be ours.
3. **Feed override is dev-only** — `SPUUpdaterDelegate.feedURLString(for:)` returns `MEDUSA_FEED_URL` from the environment **only** when the dev override is active; release builds can't be feed-hijacked via env.
4. **TCC continuity** — same bundle ID (`org.medusa.Medusa`) + same Developer ID team + default designated requirement ⇒ Accessibility/Input Monitoring grants survive updates. Operational rules: never change signing team or bundle ID casually; never overwrite the /Applications DevID install with an ad-hoc build; rotate Apple cert *or* EdDSA keys per release, never both.

## Build changes

- **Package.swift**: add `.package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.4")`, product dep `Sparkle`, and `linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]`. Commit `Package.resolved`.
- **build-app.sh**: after copying the binary — `cp -R "$ROOT/.build/$CONFIG/Sparkle.framework"` → `Contents/Frameworks/`; `rm -rf …/Versions/B/XPCServices` (not sandboxed); then **inside-out signing** on both branches (helpers `Autoupdate` + `Updater.app` → framework → app; `--options runtime --timestamp` only on the identity branch; never `--deep`). Upstream Sparkle is ad-hoc-signed, so this re-sign is mandatory for notarization and hardened-runtime library validation.
- **Resources/Info.plist**: add `SUFeedURL` = `https://raw.githubusercontent.com/rohmanhm/medusa/main/appcast.xml` and `SUPublicEDKey` = (public key from `generate_keys`). Nothing else — every other Sparkle default already matches the chosen UX. `SUVerifyUpdateBeforeExtraction` stays unset for now (would complicate dev/e2e flows; optional hardening later).
- **Versioning**: already correct — `CFBundleVersion` = `git rev-list --count HEAD` (monotonic), `CFBundleShortVersionString` = `MEDUSA_VERSION`.

## Code changes

- **New `Sources/Medusa/Updater.swift`**: `UpdaterController` (NSObject) owning `SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: self)`; takes `isLocked: () -> Bool`; implements the four gates + dev-build gate + feed override; exposes the Sparkle controller for menu targeting and `updater` for Settings bindings; `lockDidRelease()` re-presents a deferred update.
- **AppDelegate**: owns `UpdaterController(isLocked: { lock.isLocked })`; calls `updater.lockDidRelease()` from `lock.onStateChange` when unlocking; passes the updater to `MenuBarController` and `SettingsWindowController`.
- **MenuBarController**: `attachUpdater(_:)` inserts "Check for Updates…" (above Settings…) targeting the Sparkle controller. Not called in non-release builds.
- **SettingsPanes/SettingsWindow**: `GeneralPane` gains the Updates section fed by a small `UpdaterViewModel` (Combine `publisher(for:)` on the two KVO properties); `SettingsWindowController.init(updater:)` threads it through (nil ⇒ dev placeholder text).

## Release pipeline (release.sh)

After staple + re-zip + verify, three new steps:

1. `codesign --verify --deep --strict` sanity check moves **before** notarization (catch broken seals locally).
2. `sign_update` (from `.build/artifacts/sparkle/Sparkle/bin/` — version-pinned to the framework by construction) signs the final zip → `sparkle:edSignature` + `length`.
3. `scripts/update-appcast.sh <version> <build> <sig> <length>` appends an `<item>` (title, pubDate, `sparkle:version` = CFBundleVersion of the built app, `sparkle:shortVersionString`, `minimumSystemVersion` 13.0, `releaseNotesLink` → release page, enclosure → `https://github.com/rohmanhm/medusa/releases/download/v<v>/Medusa-<v>.zip`) before `</channel>` in `appcast.xml`.

Final output is an **ordered checklist**: (1) `gh release create v<v> build/Medusa-<v>.zip …` — the asset must be live first; (2) commit + push `appcast.xml` (with `Package.resolved` if changed) — the appcast going live is what turns the release on for updaters. release.sh never runs git itself.

## Verification

- **Build-level**: `swift build` clean; assembled bundle passes `codesign --verify --deep --strict`; `--self-test` still passes; `spctl -a` on release builds.
- **End-to-end (local, automated — ticket 07)**: two local builds with hand-stamped increasing `CFBundleVersion`s; EdDSA-sign the newer's zip with the real key; serve `appcast.xml` + zip over `http://localhost`; run the older with `MEDUSA_UPDATER_DEV=1`, `MEDUSA_FEED_URL=…`, and defaults `SUEnableAutomaticChecks`/`SUAutomaticallyUpdate` = true (silent path — no UI to click); Sparkle checks, downloads, EdDSA-verifies, and atomically swaps the bundle on quit; assert the on-disk app is the newer build, then clean up defaults/processes.
- **Ship-time (HITL — ticket 06)**: first real release (v0.2.0) publishes; a properly-signed lower-versioned build reads the production appcast and performs the interactive prompt → install → relaunch, with grants confirmed intact after the swap.

## Out of scope (map)

CI pipeline, DMG, Homebrew cask, delta updates, beta channels, Intel/universal builds.
