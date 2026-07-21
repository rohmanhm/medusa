# Research: Sparkle 2 integration into Medusa's Xcode-less SPM build

Resolves: `.scratch/auto-updater/issues/01-sparkle-integration.md`
Researched: 2026-07-21
Method: web research against primary sources **plus empirical verification on this machine** — a throwaway SPM package depending on Sparkle was built with the local Swift 6.2 toolchain, its artifacts inspected with `otool`/`codesign`, and a mini `.app` assembled, inside-out signed, verified (`codesign --verify --deep --strict`), and run successfully. Claims marked **[verified locally]** were observed directly.

---

## 1. Version pin

- **Pin `2.9.4`** — the latest stable tag ("2.9.4 Appcast Improvements", published 2026-07-03, `prerelease: false`). ([releases/latest](https://api.github.com/repos/sparkle-project/Sparkle/releases/latest))
- Package.swift line:

  ```swift
  .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.4")
  ```

  `from:` is safe because `Package.resolved` pins the exact resolved version *and* the binary artifact is checksum-pinned inside Sparkle's own manifest (see §2) — commit `Package.resolved`. Sparkle's README has no `.package` snippet (Xcode-UI instructions only); this is the standard form. ([README@2.9.4](https://raw.githubusercontent.com/sparkle-project/Sparkle/2.9.4/README.markdown))
- **Min macOS: 10.13 declared** (`platforms: [.macOS(.v10_13)]` in [Sparkle's Package.swift@2.9.4](https://raw.githubusercontent.com/sparkle-project/Sparkle/2.9.4/Package.swift); "Runtime: macOS 10.13 or later" in the README; `MACOSX_DEPLOYMENT_TARGET = 10.13` in [ConfigCommon.xcconfig](https://raw.githubusercontent.com/sparkle-project/Sparkle/2.9.4/Configurations/ConfigCommon.xcconfig)). The arm64 slice's `LC_BUILD_VERSION minos` is 11.0 (arm64 Macs start at Big Sur) **[verified locally]**. Either way, Medusa's macOS 13 floor is comfortably covered.
- Version-relevant behavior: **2.9.4 fixes the last known backgrounded-app focus bug** ("Fix backgrounded apps sometimes not bringing windows from user initiated actions in active focus (#2890)", [CHANGELOG](https://github.com/sparkle-project/Sparkle/blob/2.x/CHANGELOG)) — a concrete reason not to pin older.
- Sparkle ≥ 2.2 required for gentle scheduled-update behavior (§6); ≥ 2.4 ships helpers without the notarization-killing `get-task-allow` entitlement ([PR #1973](https://github.com/sparkle-project/Sparkle/pull/1973)). 2.9.4 satisfies all of it.

## 2. What SPM does (and doesn't do) for an executable target

Sparkle ships via SPM as a **binary XCFramework**: its manifest declares a single `binaryTarget` pointing at `Sparkle-for-Swift-Package-Manager.zip` with a pinned checksum (`cb6fdbdc8884f15d62a616e79face92b08322410fd2d425edc6596ccbf4ba3b0` at 2.9.4). ([Package.swift@2.9.4](https://raw.githubusercontent.com/sparkle-project/Sparkle/2.9.4/Package.swift)) SwiftPM verifies the checksum at download and re-pins it in `Package.resolved` ([SE-0272](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0272-swiftpm-binary-dependencies.md), [Apple: Distributing binary frameworks as Swift packages](https://developer.apple.com/documentation/xcode/distributing-binary-frameworks-as-swift-packages)).

`swift build`:

- **Links** the framework (`-F <slice> -framework Sparkle`) but **never embeds** — embedding is an Xcode-build-system concept; SwiftPM has no bundle model. ([swiftlang/swift-package-manager#4514](https://github.com/swiftlang/swift-package-manager/issues/4514))
- Extracts the artifact to `.build/artifacts/<package-identity>/<target-name>/` → **`.build/artifacts/sparkle/Sparkle/`** (Swift 5.7+ layout; path computed in [Workspace+BinaryArtifacts.swift](https://github.com/swiftlang/swift-package-manager/blob/main/Sources/Workspace/Workspace%2BBinaryArtifacts.swift); Sparkle's docs cite the same `../artifacts/sparkle/Sparkle/bin/` path). **[verified locally]**
- **Also copies `Sparkle.framework` next to the built binary** at `.build/<config>/Sparkle.framework`, symlink structure intact — that's how `swift run` works (the binary carries a `@loader_path` rpath). **[verified locally]**
- The linked binary's install-name reference is `@rpath/Sparkle.framework/Versions/B/Sparkle` (compat 1.6.0, current 2.9.4). **[verified locally]**; matches `DYLIB_INSTALL_NAME_BASE = @rpath` + `FRAMEWORK_VERSION = B` ([ConfigFramework.xcconfig](https://github.com/sparkle-project/Sparkle/blob/2.9.4/Configurations/ConfigFramework.xcconfig) — version "B" chosen to dodge macOS XPC-cache conflicts).

**The SPM artifact contains the CLI tools, not just the framework** — see §8.

### What the SPM zip contains **[verified locally]**

```
.build/artifacts/sparkle/Sparkle/
├── CHANGELOG, LICENSE, INSTALL, SampleAppcast.xml
├── bin/
│   ├── generate_keys      (universal arm64+x86_64)
│   ├── sign_update        (universal)
│   ├── generate_appcast   (universal)
│   ├── BinaryDelta
│   └── old_dsa_scripts/
└── Sparkle.xcframework/
    └── macos-arm64_x86_64/          ← single universal slice
        ├── Sparkle.framework/
        │   └── Versions/B/{Sparkle, Autoupdate, Updater.app,
        │                   XPCServices/{Downloader.xpc, Installer.xpc},
        │                   Headers, PrivateHeaders, Modules, Resources}
        └── dSYMs/                    ← don't ship
```

Confirmed by Sparkle's own packaging script, which stages `staging/bin` + `Sparkle.xcframework` into the SPM zip ([make-release-package.sh@2.9.4](https://raw.githubusercontent.com/sparkle-project/Sparkle/2.9.4/Configurations/make-release-package.sh)).

## 3. Embedding: rpath + copy into `Contents/Frameworks/`

### rpath

`swift build` gives the executable only `/usr/lib/swift`, `@loader_path`, and a dev-machine toolchain path **[verified locally]** — nothing that resolves `Contents/Frameworks` from `Contents/MacOS`. Sparkle's docs for non-Xcode projects: "add the flags `-Wl,-rpath,@loader_path/../Frameworks`" ([sparkle-project.org/documentation](https://sparkle-project.org/documentation/)). Two equivalent fixes:

**Option A — declarative, in Package.swift (recommended; [verified locally]):**

```swift
.executableTarget(
    name: "Medusa",
    dependencies: [.product(name: "Sparkle", package: "Sparkle")],
    path: "Sources/Medusa",
    linkerSettings: [
        .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])
    ]
)
```

`unsafeFlags` only makes a package ineligible **as a dependency of other packages** — irrelevant for a root app package ([SE-0238](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0238-package-manager-build-settings.md), [PackageDescription docs](https://docs.swift.org/package-manager/PackageDescription/PackageDescription.html)). The binary then comes out of `swift build` already correct.

**Option B — post-build in the script (the de-facto peer convention):**

```sh
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/Medusa"
```

Invalidates the linker's ad-hoc signature, which is harmless since we re-sign afterwards anyway ([Apple forums: install_name_tool vs codesign](https://developer.apple.com/forums/thread/747909)). Peers using it: [phim/build_with_spm.sh](https://github.com/roelvangils/phim/blob/HEAD/scripts/build_with_spm.sh), [muxy/build-release.sh](https://github.com/muxy-app/muxy/blob/HEAD/scripts/build-release.sh), [cmdcmd/build-app.sh](https://github.com/peterp/cmdcmd/blob/HEAD/build-app.sh).

Recommendation: **Option A** — it's part of the build definition, works for every consumer of the binary, and was proven locally end-to-end. Keep Option B in the back pocket if a toolchain change ever makes `unsafeFlags` awkward.

### Copy

Copy the whole framework, preserving symlinks (`Versions/Current` etc.) — materialized symlinks cause the classic "bundle format is ambiguous (could be app or framework)" codesign failure ([Apple TN2206](https://developer.apple.com/library/archive/technotes/tn2206/_index.html), [electron-builder#524](https://github.com/electron-userland/electron-builder/issues/524)). Sparkle docs: "make sure it preserves symlinks and executable permissions!" ([docs](https://sparkle-project.org/documentation/)). BSD `cp -R` defaults to `-P` (symlinks preserved) — **[verified locally]**; `ditto`/`rsync -a` equally fine.

```sh
# in build-app.sh, after mkdir:
mkdir -p "$APP/Contents/Frameworks"
cp -R "$ROOT/.build/$CONFIG/Sparkle.framework" "$APP/Contents/Frameworks/"
```

Source path choice: `.build/$CONFIG/Sparkle.framework` (SwiftPM's own copy next to the binary — same directory the script already reads `$BIN` from) is the simplest and was **[verified locally]**. The artifacts path (`.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework`) works too but its layout has drifted across Swift versions; robust scripts locate it with `find .build/artifacts -type d -path '*Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework'` ([VoxClaw/package_app.sh](https://github.com/malpern/VoxClaw/blob/HEAD/Scripts/package_app.sh)).

### Drop the XPC services (non-sandboxed app)

Medusa is not sandboxed, so `Downloader.xpc` and `Installer.xpc` are dead weight. Sparkle docs: "If you do not sandbox your application, you should skip this guide unless you are interested in Removing the XPC Services" and "you may choose to remove these services in a post install script when copying the framework to your application" ([sandboxing docs](https://sparkle-project.org/documentation/sandboxing/)). AltTab (non-sandboxed) ships Sparkle with no XPC services at all ([vendor/scripts/update_sparkle.sh](https://github.com/lwouis/alt-tab-macos/blob/master/vendor/scripts/update_sparkle.sh)).

```sh
rm -rf "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices"
```

**Must happen before the framework is signed** — any mutation after signing breaks the seal. `Autoupdate` and `Updater.app` stay: every Sparkle 2 install uses them to perform the update/relaunch, and they must remain reachable via the framework-root symlinks (`NSBundle URLForAuxiliaryExecutable:` only walks the framework root; breaking those symlinks yields "Cannot retrieve path for auxiliary tool: Autoupdate" — [AltTab copy_sparkle_helpers.sh](https://github.com/lwouis/alt-tab-macos/blob/master/scripts/copy_sparkle_helpers.sh)).

## 4. Signing

### The upstream signature — the critical fact

The SPM-shipped framework and all nested helpers are **ad-hoc signed** (`flags=0x10002(adhoc,runtime)`, `TeamIdentifier=not set`) **[verified locally]**; upstream builds with `CODE_SIGN_IDENTITY = -` + `ENABLE_HARDENED_RUNTIME = YES` ([ConfigCommon.xcconfig](https://raw.githubusercontent.com/sparkle-project/Sparkle/2.9.4/Configurations/ConfigCommon.xcconfig); docs: "signed with an ad-hoc signature and Hardened Runtime enabled … not ideal for distribution", [sandboxing docs](https://sparkle-project.org/documentation/sandboxing/)). Consequences:

1. **Notarization rejects it as-is** — "You can only notarize apps that you sign with a Developer ID certificate" ([Apple: Resolving common notarization issues](https://developer.apple.com/documentation/security/resolving-common-notarization-issues)); AltTab's vendor script states it plainly: "Upstream ships them adhoc-signed … notarytool rejects nested adhoc-signed Mach-O" ([update_sparkle.sh](https://github.com/lwouis/alt-tab-macos/blob/master/vendor/scripts/update_sparkle.sh)).
2. **Library validation blocks it under hardened runtime** — a hardened-runtime app may only load frameworks "signed by Apple or signed with the same Team ID as the main executable" ([Apple: disable-library-validation entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.cs.disable-library-validation)). Ad-hoc = no team ID = blocked. There is no "any Developer ID" exception.

So **every identity-signed build must re-sign Sparkle inside-out with the same identity as the app**. Conveniently, `build-app.sh`'s two paths already map onto the two safe combinations:

| Build path | App signature | Sparkle framework | Loads? |
|---|---|---|---|
| dev, ad-hoc (`-s -`, no `--options runtime`) | ad-hoc | re-sign ad-hoc (after XPC removal) | yes — no hardened runtime ⇒ no library validation |
| dev, stable identity (`--options runtime`) | Apple Development + HR | re-sign with same identity | yes — same team ID |
| release (via release.sh → build-app.sh) | Developer ID + HR + timestamp | re-sign with same Developer ID | yes — same team ID, notarizable |
| **never do**: ad-hoc app **with** `--options runtime` over a differently-signed framework | | | dyld kills it ("different Team IDs") |

The one-code-path fix: sign the framework's nested bits, then the framework, then the app, **always with whatever identity the build uses** — proven ad-hoc locally (assemble → inside-out sign → `codesign --verify --deep --strict` passes → binary loads Sparkle and runs) **[verified locally]**.

### Order and exact commands

Apple: "Sign code from the inside out" and "Don't pass the `--deep` option to codesign when you sign code" ([Creating distribution-signed code for the Mac](https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac); also Quinn's [--deep Considered Harmful](https://developer.apple.com/forums/thread/129980)). Sparkle: "please do not add `--deep` … This is a common source of Sandboxing errors" and documents the exact manual re-sign sequence ([sandboxing docs](https://sparkle-project.org/documentation/sandboxing/)). With XPC services removed, Sparkle's documented commands reduce to:

```sh
FW="$APP/Contents/Frameworks/Sparkle.framework"

# 1. mutate first (see §3), THEN sign inside-out
rm -rf "$FW/Versions/B/XPCServices"

# 2. nested helpers — hardened runtime on, no entitlements
#    (Sparkle passes none; Apple: "Don't apply entitlements to library code")
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$FW/Versions/B/Autoupdate"
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$FW/Versions/B/Updater.app"

# 3. the framework itself (root path; codesign resolves to Versions/B)
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$FW"

# 4. the app — unchanged from today, non-deep; nested signatures are
#    recorded in the outer seal, not replaced
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
```

For the ad-hoc dev path, same sequence with `--sign -` and without `--options runtime`/`--timestamp` (mirroring the script's existing split). Non-deep `codesign --force` on the app **preserves** the framework's signature — that's the whole premise of inside-out signing (Apple doc above).

### Known notarization failure modes (all avoided by the above)

- Nested **ad-hoc** Mach-O → rejected (the default failure if you skip re-signing; AltTab comment above).
- "Autoupdate/fileop must be rebuilt with support for the Hardened Runtime" — Sparkle 1.x era ([#1389](https://github.com/sparkle-project/Sparkle/issues/1389), [#1297](https://github.com/sparkle-project/Sparkle/issues/1297)); 2.x helpers ship HR-enabled, and our re-sign keeps `-o runtime`.
- `com.apple.security.get-task-allow` left on helpers → rejected ([Apple doc](https://developer.apple.com/documentation/security/resolving-common-notarization-issues)); fixed upstream since 2.4 ([PR #1973](https://github.com/sparkle-project/Sparkle/pull/1973)).
- Mutating the framework (deleting XPC services, plist edits) **after** signing → broken seal → `spctl`/notarization failure. Mutate first, sign second.
- Helpers buried where `--deep` can't see them ([#1641](https://github.com/sparkle-project/Sparkle/issues/1641)) — moot: no `--deep`, explicit per-item signing.

### What AltTab actually does (and why we don't copy it)

AltTab is Xcode-built: `OTHER_CODE_SIGN_FLAGS = --timestamp --deep --options runtime` in [release.xcconfig](https://github.com/lwouis/alt-tab-macos/blob/master/config/release.xcconfig) — exactly what Sparkle's docs prohibit — and it gets away with it only because the maintainer **pre-signs** Autoupdate/Updater.app with his Developer ID at vendor time ([update_sparkle.sh](https://github.com/lwouis/alt-tab-macos/blob/master/vendor/scripts/update_sparkle.sh)) and a build phase re-seals the framework ([copy_sparkle_helpers.sh](https://github.com/lwouis/alt-tab-macos/blob/master/scripts/copy_sparkle_helpers.sh)). Its notarize/staple/re-zip flow is shape-identical to `release.sh` already. The transferable lesson is operational, not mechanical: helpers get Developer ID + `--options runtime --timestamp`, framework re-sealed after any mutation, root symlinks intact.

## 5. Nib-less wiring

The documented programmatic pattern ([programmatic-setup docs](https://sparkle-project.org/documentation/programmatic-setup/)) — create the controller as a stored property in the app delegate (before `applicationDidFinishLaunching`), wire the menu item later:

```swift
import Sparkle

final class AppDelegate: NSObject, NSApplicationDelegate {
    let updaterController = SPUStandardUpdaterController(
        startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

    // in menu construction:
    let item = NSMenuItem(title: "Check for Updates…",
                          action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
                          keyEquivalent: "")
    item.target = updaterController
}
```

- **Menu validation is free**: "When the target/action of the menu item is set to this controller and this method, this controller also handles enabling/disabling the menu item by checking `-[SPUUpdater canCheckForUpdates]`" ([SPUStandardUpdaterController.h](https://github.com/sparkle-project/Sparkle/blob/2.x/Sparkle/SPUStandardUpdaterController.h)).
- The lower-level `SPUUpdater` + custom `SPUUserDriver` is only for replacing Sparkle's UI entirely — not needed for Medusa's peer-standard UX.
- **LSUIElement behavior is already gentle by default**: since 2.2, "For backgrounded applications (apps that do not appear in the Dock), Sparkle … will not let a scheduled update alert steal focus … Scheduled update alerts that show up after launch will be presented behind other apps and windows" ([gentle-reminders docs](https://sparkle-project.org/documentation/gentle-reminders/)). User-initiated "Check for Updates…" always activates and fronts the app (focus fix in 2.9.4, [CHANGELOG](https://github.com/sparkle-project/Sparkle/blob/2.x/CHANGELOG)). Doing nothing extra is acceptable; the only cost is a log warning about not implementing gentle reminders. Optionally adopt `SPUStandardUserDriverDelegate` (`supportsGentleScheduledUpdateReminders = true` + `standardUserDriverWillHandleShowingUpdate…`) later to add a menu-bar badge/notification ([SPUStandardUserDriverDelegate.h](https://github.com/sparkle-project/Sparkle/blob/2.x/Sparkle/SPUStandardUserDriverDelegate.h)) — that's ticket 04 territory.
- **Settings → General bindings** ([SPUUpdater.h](https://github.com/sparkle-project/Sparkle/blob/2.x/Sparkle/SPUUpdater.h)): `updater.automaticallyChecksForUpdates` (read/write, **KVO-compliant** — the auto-check toggle), `updater.canCheckForUpdates` (readonly, KVO — enables a "Check Now" button), `updater.lastUpdateCheckDate` (readonly, nullable, *not* KVO — refresh manually). Reach them via `updaterController.updater`.

## 6. Info.plist keys

Only **two** keys need adding; every other default already matches the chosen UX ([customization docs](https://sparkle-project.org/documentation/customization/)):

| Key | Value | Why |
|---|---|---|
| `SUFeedURL` | appcast URL (settled in ticket 03) | required |
| `SUPublicEDKey` | base64 EdDSA public key from `generate_keys` (ticket 03) | required |
| `SUEnableAutomaticChecks` | **leave unset** | unset ⇒ Sparkle asks for consent "on second launch"; user's answer is stored in defaults (`SUEnableAutomaticChecks`), tracked via `SUHasLaunchedBefore` ([SPUUpdater.m](https://github.com/sparkle-project/Sparkle/blob/2.x/Sparkle/SPUUpdater.m)) |
| `SUScheduledCheckInterval` | leave unset | default is already 86400 (daily) |
| `SUAutomaticallyUpdate` | leave unset | default NO ⇒ prompt-before-install; since 2.4 the consent prompt also offers auto-download, defaulting off because this key is NO |
| `SUShowReleaseNotes` | leave unset | default YES ⇒ release notes shown in the prompt |
| `SUEnableInstallerLauncherService` / `SUEnableDownloaderService` | leave unset | sandboxed-only XPC switches — not applicable |

Sparkle's monotonic-version requirement is already satisfied: `build-app.sh:50` stamps `CFBundleVersion` from `git rev-list --count HEAD`.

## 7. Proposed script changes (for the implementation tickets — NOT applied)

**Package.swift** — add the dependency, product, and rpath (§1, §3 Option A).

**build-app.sh** — after copying the binary (line ~37):

```sh
# Sparkle: embed the framework SwiftPM staged next to the binary, minus the
# sandbox-only XPC services (Medusa is not sandboxed).
mkdir -p "$APP/Contents/Frameworks"
cp -R "$ROOT/.build/$CONFIG/Sparkle.framework" "$APP/Contents/Frameworks/"
rm -rf "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices"
```

and replace the single-codesign block with inside-out signing (both identity and ad-hoc branches):

```sh
FW="$APP/Contents/Frameworks/Sparkle.framework"
if [[ -n "$IDENTITY" ]]; then
    codesign --force --options runtime --timestamp --sign "$IDENTITY" "$FW/Versions/B/Autoupdate"
    codesign --force --options runtime --timestamp --sign "$IDENTITY" "$FW/Versions/B/Updater.app"
    codesign --force --options runtime --timestamp --sign "$IDENTITY" "$FW"
    codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
else
    codesign --force --sign - "$FW/Versions/B/Autoupdate"
    codesign --force --sign - "$FW/Versions/B/Updater.app"
    codesign --force --sign - "$FW"
    codesign --force --sign - "$APP"
fi
```

**release.sh** — no signing changes needed (it already routes its Developer ID identity through `build-app.sh`, which now signs Sparkle correctly). It grows `sign_update`/appcast steps in ticket 05, calling the version-pinned tools at:

```sh
SPARKLE_BIN="$ROOT/.build/artifacts/sparkle/Sparkle/bin"   # generate_keys, sign_update, generate_appcast
```

**Verification additions** worth wiring into release.sh: `codesign --verify --deep --strict --verbose=2 "$APP"` before notarization (catches broken seals locally instead of after a 5-minute notary round-trip).

## 8. Tooling: where `generate_keys` / `sign_update` / `generate_appcast` come from

- **They ship inside the SPM artifact** at `.build/artifacts/sparkle/Sparkle/bin/` **[verified locally]** — Sparkle's docs point Xcode users at the same checkout ("you will find Sparkle's tools to generate and sign updates in `../artifacts/sparkle/Sparkle/bin/`", [docs](https://sparkle-project.org/documentation/)); the packaging script stages `bin/` into the SPM zip ([make-release-package.sh](https://raw.githubusercontent.com/sparkle-project/Sparkle/2.9.4/Configurations/make-release-package.sh)). Peers invoke them straight from there ([palmier-pro/bundle.sh](https://github.com/palmier-io/palmier-pro/blob/HEAD/scripts/bundle.sh)).
- **Version pinning is automatic by construction**: the tools come out of the exact checksum-pinned zip SPM resolved, so tools == framework version always. No separate download, no drift.
- Alternatives rejected: the `Sparkle-2.9.4.tar.xz` release asset also contains `bin/` but is a second, manually-synced download; **Homebrew is a dead end** — the `sparkle` cask installs only "Sparkle Test App.app" (no CLI tools) and is disabled 2026-09-01 for `:fails_gatekeeper_check` ([homebrew-cask/sparkle.rb](https://github.com/Homebrew/homebrew-cask/blob/HEAD/Casks/s/sparkle.rb)); no formula exists.
- Caveat: the tools exist only after a `swift build`/`swift package resolve` — fine, since every script path builds first.

## 9. Empirical verification log (2026-07-21, this machine, Swift 6.2 / Xcode 26.2 toolchain)

Throwaway package at `<scratchpad>/sparkletest` (outside the repo), `from: "2.0.0"` → resolved **2.9.4**:

1. `swift build -c release` downloaded `Sparkle-for-Swift-Package-Manager.zip`, extracted to `.build/artifacts/sparkle/Sparkle/` (layout as in §2), and copied `Sparkle.framework` to `.build/release/` with symlinks intact.
2. `otool -L`: binary references `@rpath/Sparkle.framework/Versions/B/Sparkle`. `otool -l`: default rpaths `/usr/lib/swift`, `@loader_path`, toolchain path — plus `@executable_path/../Frameworks` added by the `unsafeFlags` linker setting.
3. `codesign -dvv` on framework, `Autoupdate`, `Updater.app`: all `flags=0x10002(adhoc,runtime)`, `TeamIdentifier=not set`.
4. Mini .app assembled (binary → `Contents/MacOS`, `cp -R` framework → `Contents/Frameworks`), signed inside-out ad-hoc (XPC services, Autoupdate, Updater.app, framework, app): `codesign --verify --deep --strict` → "valid on disk … satisfies its Designated Requirement"; running the binary instantiated `SPUStandardUpdaterController` successfully.
5. `bin/` tools are universal (arm64 + x86_64) Mach-O executables; framework Info.plist reports 2.9.4 (build 2059); framework arm64 slice `minos 11.0`.

One correction made during synthesis: a web-research pass claimed the SPM artifact carries Sparkle's "original Developer ID signature" — the local `codesign -dvv` (point 3), Sparkle's own docs, and AltTab's vendor script all say **ad-hoc**. Ad-hoc it is.

## Sources

- Sparkle documentation: https://sparkle-project.org/documentation/ (manual install, rpath flags, tools location, library-validation note)
- Sparkle sandboxing/code-signing: https://sparkle-project.org/documentation/sandboxing/ (re-sign commands, no-`--deep`, XPC removal, ad-hoc upstream signing)
- Sparkle programmatic setup: https://sparkle-project.org/documentation/programmatic-setup/
- Sparkle gentle reminders: https://sparkle-project.org/documentation/gentle-reminders/
- Sparkle customization (plist keys): https://sparkle-project.org/documentation/customization/
- Sparkle 2.9.4 tag: Package.swift, README, CHANGELOG, ConfigCommon.xcconfig, ConfigFramework.xcconfig, make-release-package.sh, make-xcframework.sh — https://github.com/sparkle-project/Sparkle/tree/2.9.4
- Sparkle headers: SPUUpdater.h, SPUStandardUpdaterController.h, SPUStandardUserDriverDelegate.h, SPUUpdater.m — https://github.com/sparkle-project/Sparkle/tree/2.x/Sparkle
- Sparkle issues/PRs: #1389, #1297, #1641, #1701, #1973, #2097 — https://github.com/sparkle-project/Sparkle
- Apple — Creating distribution-signed code for the Mac: https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac
- Apple — Resolving common notarization issues: https://developer.apple.com/documentation/security/resolving-common-notarization-issues
- Apple — disable-library-validation entitlement (library-validation rule): https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.cs.disable-library-validation
- Apple — Hardened Runtime: https://developer.apple.com/documentation/security/hardened-runtime
- Apple — Distributing binary frameworks as Swift packages: https://developer.apple.com/documentation/xcode/distributing-binary-frameworks-as-swift-packages
- Apple — TN2206 (framework symlinks): https://developer.apple.com/library/archive/technotes/tn2206/_index.html
- Quinn — "--deep Considered Harmful": https://developer.apple.com/forums/thread/129980
- SwiftPM — SE-0238 (unsafeFlags), SE-0272 (binary deps), #4514 (link-not-embed), Workspace+BinaryArtifacts.swift: https://github.com/swiftlang/swift-package-manager / https://github.com/swiftlang/swift-evolution
- AltTab — release.xcconfig, vendor/scripts/update_sparkle.sh, scripts/copy_sparkle_helpers.sh, scripts/package_and_notarize_release.sh: https://github.com/lwouis/alt-tab-macos
- Peer SPM-only scripts: https://github.com/roelvangils/phim/blob/HEAD/scripts/build_with_spm.sh, https://github.com/muxy-app/muxy/blob/HEAD/scripts/build-release.sh, https://github.com/peterp/cmdcmd/blob/HEAD/build-app.sh, https://github.com/smnandre/symfony-cli-menubar/blob/HEAD/scripts/embed_sparkle.sh, https://github.com/malpern/VoxClaw/blob/HEAD/Scripts/package_app.sh
- Homebrew sparkle cask (disabled): https://github.com/Homebrew/homebrew-cask/blob/HEAD/Casks/s/sparkle.rb
