# Research: Update safety — TCC grants and the engaged lock

Resolves: `.scratch/auto-updater/issues/02-update-safety.md`
Researched: 2026-07-21

---

## Verdict

An in-place Sparkle 2 update is **safe for Medusa's TCC grants** as long as every release keeps the same bundle ID and the same Developer ID team with the default designated requirement — which is exactly what `release.sh` already produces. The updater must be gated at four Sparkle layers so it is inert while the lock is engaged (§2), and it must never run at all in ad-hoc dev builds (§3) — not because Sparkle would refuse the update (it wouldn't, surprisingly — §3.1), but because installing a Developer ID build over the ad-hoc TCC identity churns the grants.

---

## 1. TCC persistence across in-place updates

### 1.1 How TCC keys a grant

Grants live in the `access` table of two SQLite databases; **both Accessibility (`kTCCServiceAccessibility`) and Input Monitoring (`kTCCServiceListenEvent`) live in the system-wide one** at `/Library/Application Support/com.apple.TCC/TCC.db` ([HackTricks TCC](https://hacktricks.wiki/en/macos-hardening/macos-security-and-privilege-escalation/macos-security-protections/macos-input-monitoring-screen-capture-accessibility.html), [Karol Mazurek — Snake&Apple IX](https://karol-mazurek.medium.com/snake-apple-ix-tcc-ae822e3e2718)). Each row is keyed by:

- `client` — the bundle ID (`com.rohmanhm.medusa`), and
- `csreq` — a compiled copy of the app's **designated requirement (DR)**, the anti-impersonation check.

For a Developer ID app the stored DR is the default codesign template — effectively `identifier "com.x" and anchor apple generic and certificate leaf[Developer ID] and certificate leaf[subject.OU] = TEAMID` (real dump in [Apple forums 703188](https://developer.apple.com/forums/thread/703188)). Apple documents the mechanism in [TN3127: Inside Code Signing — Requirements](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements): macOS "records your app's DR in its database of apps authorized to access the microphone… Each time your app tries to access [it], macOS checks that this version of the app satisfies the original DR." The default DR is deliberately built so that *any version* of the app satisfies it, but no other app does.

They are **independent rows**: Accessibility, Input Monitoring (`ListenEvent`) and `PostEvent` are "three independent buckets, three separate rows in TCC.db" (Quinn, via [thread 744440](https://developer.apple.com/forums/thread/744440)) — one surviving an update says nothing about the other, though both survive or break for the same csreq reasons.

### 1.2 What preserves grants — CONFIRMED

Same bundle ID + same Developer ID team + default DR ⇒ the new version satisfies the stored csreq ⇒ **no re-prompt**. Sources:

- TN3127 (above) — the DR-in-database flow exists precisely for this.
- Quinn (Apple DTS, [thread 730043](https://developer.apple.com/forums/thread/730043)): "sign your code with a stable signing identity… Developer ID for final distribution. Doing this will radically cut down on the amount of TCC thrash."
- Sparkle maintainer on this exact scenario ([Sparkle #1625](https://github.com/sparkle-project/Sparkle/issues/1625)): grant loss after update "happen[s] to applications that aren't Apple-code-signed, or which changed signing identity between updates."
- Peer silence as evidence: targeted searches of Rectangle, AltTab, Maccy, Ice, MonitorControl issue trackers found **zero** reports of a normal Sparkle update re-prompting for Accessibility/Input Monitoring, across hundreds of thousands of updated installs.

One mechanical caveat: the replacement must be **atomic whole-bundle** (new inode), never in-place file modification — the kernel caches signature state per-inode ([Apple: Updating Mac Software](https://developer.apple.com/documentation/security/updating-mac-software), Quinn in [703188](https://developer.apple.com/forums/thread/703188)). Sparkle 2's installer does exactly this ("Rewrites file operations for updating an app to be atomic", [Sparkle CHANGELOG](https://raw.githubusercontent.com/sparkle-project/Sparkle/2.x/CHANGELOG)).

### 1.3 What breaks grants

| Change | Effect | Evidence |
|---|---|---|
| **Signing team / cert chain change** | DR's `subject.OU` no longer matches. Worst failure mode: app loses access **but can't re-prompt because System Settings still shows it granted**; only `tccutil reset` untangles it | [Apple forums 785384](https://developer.apple.com/forums/thread/785384); real-world: the 2024 Bartender acquisition re-sign, whose remediation page tells users to `tccutil reset Accessibility com.surteesstudios.Bartender` ([MacRumors](https://www.macrumors.com/2024/06/04/bartender-mac-app-new-owner/), [macbartender.com](https://www.macbartender.com/Bartender5/PermissionIssues/)) |
| **Bundle ID change** | Entirely new client; old grants orphaned, fresh prompts | Quinn recommends it as the *deliberate* clean-slate move ([785384](https://developer.apple.com/forums/thread/785384)); the re-signed Ice fork told users to re-grant everything for its new bundle ID ([Ice #966](https://github.com/jordanbaird/Ice/issues/966)) |
| **Developer ID → ad-hoc (or any ad-hoc build)** | Ad-hoc DR is `cdhash H"…"` — pinned to that exact binary, changes every rebuild; "macOS is unable to tell that version N+1 of your app is the 'same code' as version N" | [TN3127](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements) ("Ad hoc signed code… has a DR but it's tied to that specific version of the code"); Quinn, [thread 795739](https://developer.apple.com/forums/thread/795739) |
| **Unsigned** | No DR at all; re-prompt every build | TN3127 |
| **Custom/changed DR** | Stored csreq no longer satisfied ⇒ different client; tccd never "migrates" an entry | [mothersruin — All About Code Signing](https://www.mothersruin.com/software/Archaeology/reverse/codesign.html) |

**Failure mode on csreq mismatch** is not documented by Apple; the community record shows two behaviors: (a) silent denial with a stale "on" checkbox and no re-prompt (team-change case, [785384](https://developer.apple.com/forums/thread/785384)); (b) treated-as-new-app with a fresh prompt (ad-hoc case, [795739](https://developer.apple.com/forums/thread/795739)). Separately, macOS itself has version bugs where grants look on but are dead (Sonoma 14.0–14.1 boot race — [kevinyank.com](https://kevinyank.com/posts/privacy-security-settings-reset/); Rectangle maintainer: "accessibility permissions being out of sync", fix is remove-and-re-add or `tccutil reset All com.knollsoft.Rectangle` — [Rectangle #1461](https://github.com/rxhanson/Rectangle/issues/1461); Karabiner Input Monitoring toggle bugs — [#3343](https://github.com/pqrs-org/Karabiner-Elements/issues/3343), [#4313](https://github.com/pqrs-org/Karabiner-Elements/issues/4313)). Those are OS flakiness, not update-caused — but they're the support tickets Medusa should expect regardless of Sparkle.

### 1.4 Peer evidence on updating under a live event tap

The one concrete incident is what happens when Sparkle is *bypassed*: `brew upgrade --cask alt-tab` swaps the bundle under AltTab's running process while it owns a system-wide event tap, producing ~5-second system-wide input lockups per modifier press; the maintainer's verdict was "use the in-app Sparkle update", which quits before swapping ([AltTab #5108](https://github.com/lwouis/alt-tab-macos/issues/5108)). No Rectangle/AltTab issues report a Sparkle-driven relaunch breaking anything — because Sparkle's quit→swap→relaunch ordering never replaces a bundle under a live process. For Medusa the analogous hazard is precisely "install/relaunch while the shield + tap are engaged," handled in §2.

---

## 2. Never update under lock — the exact Sparkle 2 gating surface

Verified against the current 2.x headers ([SPUUpdaterDelegate.h](https://raw.githubusercontent.com/sparkle-project/Sparkle/2.x/Sparkle/SPUUpdaterDelegate.h), [SPUStandardUserDriverDelegate.h](https://raw.githubusercontent.com/sparkle-project/Sparkle/2.x/Sparkle/SPUStandardUserDriverDelegate.h), [SPUUpdater.h](https://raw.githubusercontent.com/sparkle-project/Sparkle/2.x/Sparkle/SPUUpdater.h)). Sparkle 1's `updaterMayCheckForUpdates(_:)` and `updater(_:shouldAllowInstallerInteractionFor:)` are deprecated/removed — do not design against them.

### Layer 1 — veto all checks: `updater(_:mayPerform:)`

```swift
// SPUUpdaterDelegate — one method vetoes scheduled AND user-initiated checks and probes
func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
    if lockController.isLocked {
        throw NSError(domain: "Medusa", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "Updates pause while the lock is engaged."])
    }
}
```

`SPUUpdateCheck` distinguishes `.updates` (user-initiated), `.updatesInBackground` (scheduled), `.updateInformation` (probe) — Medusa vetoes all three while locked. Header doc names our use case verbatim: "this may be used to prevent Sparkle from interrupting a setup assistant." **Nuance:** unlike Sparkle 1, this veto does *not* feed menu-item validation — `canCheckForUpdates` is pure session state. If the menu's "Check for Updates…" should appear disabled during a lock, disable it ourselves (moot in practice: the shield blocks all input while locked, so only the *scheduled* check is a real threat).

### Layer 2 — scheduled-update UI: gentle reminders (`SPUStandardUserDriverDelegate`)

A check that completed *just before* the lock engaged can still want to present an alert. Sparkle ≥ 2.2's gentle-reminders API gates presentation:

```swift
var supportsGentleScheduledUpdateReminders: Bool { true }  // also silences the log warning for dockless apps

func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem,
                                                          andInImmediateFocus immediateFocus: Bool) -> Bool {
    !lockController.isLocked   // while locked: we take responsibility and simply defer
}
```

Returning `false` makes the delegate responsible for showing the update later — the documented re-entry is calling `updater.checkForUpdates()` on unlock ([gentle reminders doc](https://sparkle-project.org/documentation/gentle-reminders/)). That page's second example is literally a menu-bar (`.accessory`) app. Note "Background (dockless) running apps may receive a log warning about scheduling update checks and not implementing gentle reminders" — implementing this is expected hygiene for an LSUIElement app, not an extra.

### Layer 3 — stall a pending silent install: `updater(_:willInstallUpdateOnQuit:immediateInstallationBlock:)`

```swift
func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
             immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool
```

Called when an auto-downloaded update is scheduled to install on quit. Returning `true` and **not invoking the handler** is the documented way to stall the cycle ("This stalls the current update cycle and prevents future update cycles from running"); invoke the held handler on unlock if an immediate silent install is desired, or return `false` to let Sparkle re-present later. Either way "Sparkle will always attempt to install the update when the app terminates" — which is fine: Medusa quitting means the lock is down. With Medusa's charted prompt-before-install defaults (no silent installs) this path is unlikely, but guarding it costs three lines.

### Layer 4 — relaunch guards

```swift
func updaterShouldRelaunchApplication(_ updater: SPUUpdater) -> Bool { !lockController.isLocked }

func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
             untilInvokingBlock installHandler: @escaping () -> Void) -> Bool
```

`shouldPostponeRelaunchForUpdate` only exists in the block form on `SPUUpdaterDelegate` (the block-less variant is Sparkle-1-compat only), and it fires **after** the user already chose "Install and Relaunch" — it delays the relaunch, not the install/termination, so it is a last-resort backstop, not the primary gate. The relaunch itself is performed by Sparkle's external progress agent (`Updater.app`, [InstallerProgressAppController.m](https://raw.githubusercontent.com/sparkle-project/Sparkle/2.x/Sparkle/InstallerProgress/InstallerProgressAppController.m)): once install begins, *our process is asked to terminate and an outside agent relaunches the app*. That is why layers 1–3 must prevent ever reaching the install stage while locked.

### Residual window

A veto blocks *new* checks; it does not tear down a session already in flight (`sessionInProgress` covers appcast/download/UI/installer-start — [SPUUpdater.h](https://raw.githubusercontent.com/sparkle-project/Sparkle/2.x/Sparkle/SPUUpdater.h)), and there is no cancel API. In practice this is closed by Medusa's own design: prompt-before-install means installation requires a user click, and the shield + event tap block all input while locked. The only reachable mid-lock artifact is an alert sitting behind/under the shield until unlock. Acceptable; no extra machinery needed.

---

## 3. Dev builds: compile the updater out of the path

### 3.1 The surprise: Sparkle would *accept* the cross-signed update

Sparkle 2's validator ([SUUpdateValidator.m](https://raw.githubusercontent.com/sparkle-project/Sparkle/2.x/Sparkle/SUUpdateValidator.m)) accepts a bundle update if **either** (a) EdDSA validates against the old app's `SUPublicEDKey`, **or** (b) the new bundle satisfies the old bundle's designated requirement ("Either DSA must be valid, or Apple Code Signing must be valid… this allows key rotation"). An ad-hoc dev build carrying the production `SUPublicEDKey` would therefore **accept and install** a notarized Developer ID release zip (EdDSA branch passes; the DevID build merely needs a self-valid signature). Nothing in Sparkle stops the ad-hoc→DevID swap — the damage is purely TCC-side: the stored csreq is the ad-hoc build's cdhash, so the installed DevID build is a different client (§1.3) and the grants churn. The protection has to be ours.

Secondary reasons to gate: a dev build auto-checking the production appcast would nag with real update prompts; and Sparkle's docs warn that with library validation (hardened runtime), ad-hoc-signed apps may not even load Sparkle ([docs](https://sparkle-project.org/documentation/), [Sparkle #2056](https://github.com/sparkle-project/Sparkle/issues/2056)) — not currently Medusa's case (`build-app.sh` ad-hoc branch signs without `--options runtime`), but it becomes relevant if dev builds ever adopt hardened runtime.

### 3.2 Peer patterns

- **Ice** — compile-time: `#if DEBUG` replaces `checkForUpdates()` with an alert ("Checking for updates is not supported in debug mode") ([UpdatesManager.swift](https://github.com/jordanbaird/Ice/blob/main/Ice/Updates/UpdatesManager.swift)).
- **Maccy** — runtime: `#if DEBUG` + `enable-testing` sets `automaticallyChecksForUpdates = false` ([AppDelegate.swift](https://github.com/p0deje/Maccy/blob/master/Maccy/AppDelegate.swift)).
- **AltTab** — `SPUStandardUpdaterController(startingUpdater: false, …)` + deferred `startUpdater()`, per-developer feed override via xcconfig, and — most relevant — a persistent **"Local Self-Signed" certificate for all dev builds specifically "to avoid having to re-check the System Preferences > Security & Privacy permissions on every build"** ([contributing.md](https://github.com/lwouis/alt-tab-macos/blob/master/docs/contributing.md), [base.xcconfig](https://github.com/lwouis/alt-tab-macos/blob/master/config/base.xcconfig)) — direct maintainer acknowledgement of ad-hoc TCC churn.
- **Rectangle / MonitorControl** — no debug gating (updater constructed unconditionally); they tolerate dev builds seeing the production feed.

### 3.3 Recommendation for Medusa

Two independent guards, both cheap:

1. **Never start the updater in non-release builds.** The sanctioned off-switch is not starting it: construct `SPUStandardUpdaterController(startingUpdater: false, …)` and call `startUpdater()` only when the running bundle is release-signed. Since Medusa builds via SwiftPM + scripts (no xcconfig), the cleanest test is a runtime one — check the app's own signing for a Developer ID anchor (`SecCodeCopySigningInformation` team ID; ad-hoc builds return nil team) or gate on a compile flag `release.sh` sets. Before `startUpdater()` is called, Sparkle does nothing: no permission prompt, no scheduled checks ([SPUStandardUpdaterController.h](https://raw.githubusercontent.com/sparkle-project/Sparkle/2.x/Sparkle/SPUStandardUpdaterController.h)).
2. **Keep steering dev workflow toward a stable identity** (already in README: `MEDUSA_SIGN_IDENTITY=…`), the AltTab pattern — this fixes dev-build TCC churn independent of Sparkle.

And one operational rule from §1.3: **never overwrite the `/Applications` Developer ID install with an ad-hoc build** (or vice versa) — that is the classic self-inflicted way to land in the stale-checkbox / silent-denial TCC state that only `tccutil reset Accessibility`/`ListenEvent` clears.

---

## 4. Install privileges in /Applications

The silent-vs-authorization decision is `SPUSystemNeedsAuthorizationAccessForBundlePath()` ([SUInstallerLauncher.m](https://raw.githubusercontent.com/sparkle-project/Sparkle/2.x/InstallerLauncher/SUInstallerLauncher.m)):

- App bundle + parent directory writable by the current user, **and** the user can set matching owner/group on a test file ⇒ **fully silent install, no password**. This is Medusa's case: user-dragged into `/Applications`, owned by that user.
- Not writable, or owned by root/another user (sudo install, other admin account, pkg) ⇒ macOS **authorization prompt**, executed via a launchd-submitted privileged helper (Sparkle 2 dropped `AuthorizationExecuteWithPrivileges`). Guided *package* installs always use the system domain — irrelevant for our zip.
- If auth would be needed during a silent background install, Sparkle returns `SUInstallerLauncherAuthorizeLater` and retries when interaction is allowed — it never throws a password dialog at an unattended machine.

LSUIElement interactions are all benign and documented: Sparkle 2.2+ activates the app when a check comes from a menu-bar extra ([CHANGELOG](https://raw.githubusercontent.com/sparkle-project/Sparkle/2.x/CHANGELOG)); scheduled alerts for dockless apps won't steal focus except right after launch; the gentle-reminders API (§2 Layer 2) exists specifically for background apps.

---

## Implications for other tickets

- **[03 — keys/appcast]**: Sparkle's key-rotation rule — you may rotate the Apple cert *or* the EdDSA keys per update, never both ([docs](https://sparkle-project.org/documentation/)); guard the EdDSA private key accordingly. `SUVerifyUpdateBeforeExtraction` tightens pre-extraction fallback to a Developer ID *team match* — worth considering since our host is always DevID in release.
- **[04 — wire updater]**: the check-veto does not gray out the "Check for Updates…" menu item — validate it manually against `lockController.isLocked` (or leave it; shield blocks clicks anyway). Implement `supportsGentleScheduledUpdateReminders` to avoid the dockless-app log warning.
- **[05 — release.sh]**: no new constraints; the atomic-install + same-DR requirements are met by the existing DevID sign → notarize → staple → zip flow.

## Sources

**Apple / primary**
- TN3127 — Inside Code Signing: Requirements: https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements
- Updating Mac Software (atomic replacement): https://developer.apple.com/documentation/security/updating-mac-software
- Quinn/DTS forum threads: https://developer.apple.com/forums/thread/703188 , /730043 , /785384 , /795739 , /707177 , /744440

**TCC deep-dives (community reverse-engineering)**
- Karol Mazurek — Snake&Apple IX (TCC): https://karol-mazurek.medium.com/snake-apple-ix-tcc-ae822e3e2718
- HackTricks — TCC / Input Monitoring: https://hacktricks.wiki/en/macos-hardening/macos-security-and-privilege-escalation/macos-security-protections/macos-input-monitoring-screen-capture-accessibility.html
- yo-yo-yo-jbo — macOS TCC: https://github.com/yo-yo-yo-jbo/macos_tcc/
- mothersruin — All About Code Signing: https://www.mothersruin.com/software/Archaeology/reverse/codesign.html
- Eclectic Light — What's in an app's signature: https://eclecticlight.co/2022/03/08/whats-in-an-apps-signature/
- Rainforest QA — TCC.db deep dive: https://www.rainforestqa.com/blog/macos-tcc-db-deep-dive
- jano.dev — Accessibility permission: https://jano.dev/apple/macos/swift/2025/01/08/Accessibility-Permission.html
- kevinyank.com — Sonoma privacy-settings reset: https://kevinyank.com/posts/privacy-security-settings-reset/

**Sparkle 2 (docs + 2.x source)**
- Documentation: https://sparkle-project.org/documentation/ ; gentle reminders: https://sparkle-project.org/documentation/gentle-reminders/ ; customization: https://sparkle-project.org/documentation/customization/ ; security: https://sparkle-project.org/documentation/security-and-reliability/
- Headers/source (2.x branch): SPUUpdaterDelegate.h, SPUStandardUserDriverDelegate.h, SPUUpdater.h/.m, SPUStandardUpdaterController.h, SUUpdateValidator.m, InstallerLauncher/SUInstallerLauncher.m, InstallerProgress/InstallerProgressAppController.m, CHANGELOG — under https://github.com/sparkle-project/Sparkle/tree/2.x
- Sparkle issues: #1625 (grants lost ⇒ signing identity changed), #2056 (ad-hoc + library validation), #1401/#680 (insecure-update errors in unsigned dev runs): https://github.com/sparkle-project/Sparkle/issues/1625 , /2056 , /1401 , /680

**Peer evidence**
- AltTab: brew-swap-under-live-tap incident https://github.com/lwouis/alt-tab-macos/issues/5108 ; self-signed dev cert https://github.com/lwouis/alt-tab-macos/blob/master/docs/contributing.md , https://github.com/lwouis/alt-tab-macos/blob/master/config/base.xcconfig ; updater start https://github.com/lwouis/alt-tab-macos/blob/master/src/App.swift
- Rectangle: TCC desync #1461 https://github.com/rxhanson/Rectangle/issues/1461 , #1074, #1120; unconditional updater https://github.com/rxhanson/Rectangle/blob/main/Rectangle/AppDelegate.swift
- Ice: DEBUG-gated updates https://github.com/jordanbaird/Ice/blob/main/Ice/Updates/UpdatesManager.swift ; re-signed fork must re-grant https://github.com/jordanbaird/Ice/issues/966
- Maccy: test-run check disabling https://github.com/p0deje/Maccy/blob/master/Maccy/AppDelegate.swift
- MonitorControl: deferred startUpdater https://github.com/MonitorControl/MonitorControl/blob/main/MonitorControl/Support/AppDelegate.swift ; unsigned-fork re-prompts #169 https://github.com/MonitorControl/MonitorControl/issues/169
- Karabiner-Elements: Input Monitoring toggle bugs #3343, #2536, #4313 https://github.com/pqrs-org/Karabiner-Elements/issues/3343 , /2536 , /4313
- Bartender team-change incident: https://www.macrumors.com/2024/06/04/bartender-mac-app-new-owner/ , https://www.macbartender.com/Bartender5/PermissionIssues/
