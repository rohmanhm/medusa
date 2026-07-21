# Sparkle 2 build integration

Type: research
Status: resolved

## Question

How does Sparkle 2 integrate into Medusa's unusual build — an SPM executable target (swift-tools 6, Swift 5 language mode, zero deps today) assembled into a `.app` by `scripts/build-app.sh`, with **no Xcode project**?

- **SPM dependency**: Sparkle 2 ships as a binary XCFramework via SPM. What does SPM link automatically for an *executable* target, and what does an Xcode-less build have to do by hand? Pin which Sparkle version (latest 2.x) and its actual min-macOS (must cover macOS 13).
- **Embedding**: what must land in `Contents/Frameworks/` (Sparkle.framework with its internal XPC services — Downloader.xpc, Installer.xpc — and Autoupdate/Updater helpers)? Where does `swift build` leave the framework, and what does `build-app.sh` copy? Does the SPM-built binary need an added `LC_RPATH` (`@executable_path/../Frameworks`), and how (`-Xlinker -rpath` in Package.swift vs `install_name_tool` in the script)?
- **Signing order** under hardened runtime + notarization: inside-out signing of Sparkle's nested helpers/framework before the app; which components need their own hardened-runtime flags/entitlements; known notarization rejections. What AltTab's scripts do (it consumes Sparkle and signs in CI without... verify how). Implications split across `build-app.sh` (ad-hoc/dev) and `release.sh` (Developer ID).
- **Nib-less wiring**: instantiating `SPUStandardUpdaterController` (or `SPUUpdater`) purely from code in an AppKit app with no storyboard/nib; LSUIElement/menu-bar-app caveats (update windows and focus for a background app — "gentle reminders").
- **Info.plist keys**: `SUFeedURL`, `SUPublicEDKey`, and the right automatic-check keys for the chosen UX (Sparkle consent prompt on, daily checks, prompt-before-install — see map Notes).
- **Tooling**: when Sparkle comes in via SPM, where do `generate_keys`, `sign_update`, `generate_appcast` come from (SPM artifacts checkout? the separate Sparkle release tarball?) and how to pin them to the same version.

Findings file: `.scratch/auto-updater/research/01-sparkle-integration.md`

## Answer

Full findings (with exact commands, plist keys, script fragments, and a Sources section): `.scratch/auto-updater/research/01-sparkle-integration.md`. Every mechanic below was additionally **verified empirically on this machine** with a throwaway SPM package (build → embed → inside-out sign → `codesign --verify --deep --strict` → run).

- **Pin Sparkle 2.9.4** (`.package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.4")`, commit `Package.resolved`). Min macOS 10.13 declared (arm64 slice 11.0) — macOS 13 covered. 2.9.4 also fixes the last LSUIElement focus bug.
- **SPM links but never embeds** (no bundle model). The checksum-pinned artifact lands at `.build/artifacts/sparkle/Sparkle/` and — bonus — `swift build` copies `Sparkle.framework` (symlinks intact) right next to the binary at `.build/<config>/Sparkle.framework`, which is the simplest copy source for `build-app.sh` (`cp -R` → `Contents/Frameworks/`).
- **rpath**: the swift-build binary has no usable rpath for `Contents/Frameworks`; add `@executable_path/../Frameworks` via `linkerSettings: [.unsafeFlags([...])]` in Package.swift (verified working; legal for a root package) — or `install_name_tool -add_rpath` post-build (the peer convention).
- **Delete the XPC services** (`Versions/B/XPCServices` — sandboxed-only per Sparkle docs; AltTab ships without them). Keep `Autoupdate` + `Updater.app` and their framework-root symlinks. Mutate **before** signing.
- **Upstream Sparkle is ad-hoc signed** (verified: `TeamIdentifier=not set`), so it both fails notarization and is blocked by library validation under hardened runtime. Fix: sign inside-out with the build's identity in `build-app.sh` (helpers → framework → app; `--options runtime --timestamp` on the identity branch, plain `-` on the ad-hoc branch; **never `--deep`** — both Apple and Sparkle prohibit it). `release.sh` needs no signing changes since it routes its Developer ID through `build-app.sh`.
- **Nib-less wiring**: `SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)` as a stored property in the app delegate; menu item target/action to `checkForUpdates(_:)` gets enable/disable validation free. Sparkle ≥2.2 is already gentle for dockless apps (scheduled alerts don't steal focus). Settings bindings: `automaticallyChecksForUpdates` (KVO), `canCheckForUpdates` (KVO), `lastUpdateCheckDate` (not KVO).
- **Info.plist**: add only `SUFeedURL` + `SUPublicEDKey` (values from ticket 03). All other defaults already equal the chosen UX — consent prompt on second launch (leave `SUEnableAutomaticChecks` unset), daily checks (86400 default), prompt-before-install with release notes.
- **Tooling**: `generate_keys`/`sign_update`/`generate_appcast` ship **inside the SPM artifact** at `.build/artifacts/sparkle/Sparkle/bin/` — version-pinned to the framework by construction. Homebrew's sparkle cask is a dead end (no tools, disabled 2026-09).

## Comments
