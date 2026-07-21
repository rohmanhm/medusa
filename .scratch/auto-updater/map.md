# Map: Medusa auto-updater

Labels: wayfinder:map

## Destination

A published Medusa release whose in-app **Sparkle 2** updater is proven end-to-end on the dev machine: an older installed build surfaces the new release in-app, downloads, installs, and relaunches into it. The map closes when that proof has run against real GitHub Release assets.

## Notes

- **GOAL OVERRIDE (2026-07-21)**: the user directed spec → tickets → implement → verify in one push (`/goal`). The spec is [spec.md](spec.md); tickets 03/04/05/07 are executed inline by the agent; ticket 06 (publishing the release) stays HITL — commits, pushes, and `gh release create` require explicit approval.
- **Execution lives in this map** (declared at charting, unlike v1's mid-way override): the destination is a shipped release, so implementation tickets are in scope, not just decisions.
- **Skills**: `/research` for research tickets; `/grilling` + `/domain-modeling` if a decision ticket appears.
- **Tracker**: local markdown per `docs/agents/issue-tracker.md`. Research findings live under `.scratch/auto-updater/research/` (repo convention from v1 — no auto-commits, no research branches).
- **Charting decisions** (made while naming the destination, no tickets behind them):
  - **Sparkle 2 via SPM** — Medusa's first third-party dependency. Consciously supersedes the v1 zero-deps rule ([tech stack](../v1-spec/issues/08-tech-stack.md), where Sparkle was "deferred with distribution", not rejected). Owning security-critical update code was judged worse than one hardened dep; Stats' custom updater is the cautionary peer.
  - **Full in-app install UX, peer-standard defaults**: Sparkle's built-in consent prompt (ask on ~second launch), daily background checks, prompt-before-install with release notes (no silent installs), "Check for Updates…" in the menu-bar menu plus an Updates row in Settings → General.
  - **Pipeline stays local**: `release.sh` grows `sign_update` + appcast steps; tag-triggered CI is out of scope.
  - **Artifact stays the notarized stapled-app zip** (`Medusa-<version>.zip`); the Sparkle enclosure points at the GitHub Release asset. AltTab ships exactly this. DMG migration out of scope.
  - **Appcast** = `appcast.xml` committed to this repo, served over a raw/Pages URL (exact URL settled in [EdDSA keys & appcast bootstrap](issues/03-keys-appcast-bootstrap.md)).
- **Facts**: `CFBundleVersion` is already monotonic — `build-app.sh:50` stamps it with `git rev-list --count HEAD`; `CFBundleShortVersionString` comes from `MEDUSA_VERSION`. Sparkle's monotonic-version requirement is satisfied as-is.
- Prior art: `.scratch/v1-spec/research/04-distribution.md` §4 already surveys Sparkle 2 vs custom vs brew and peer pipelines (Rectangle/AltTab/Stats) — read it before re-researching.

## Decisions so far

<!-- one line per closed ticket: gist + link -->

- [Sparkle 2 build integration](issues/01-sparkle-integration.md) — pin 2.9.4 via SPM (CLI tools ship version-pinned inside the artifact at `.build/artifacts/sparkle/Sparkle/bin/`); `cp -R` the framework from `.build/<config>/`, add `@executable_path/../Frameworks` rpath in Package.swift, delete the sandbox-only XPC services, and sign inside-out with the build's identity (upstream is ad-hoc-signed, so Developer ID re-sign is mandatory for notarization; never `--deep`); plist adds only `SUFeedURL` + `SUPublicEDKey`; whole flow empirically verified locally — findings in [research/01-sparkle-integration.md](research/01-sparkle-integration.md).
- [Update safety: TCC grants and the engaged lock](issues/02-update-safety.md) — same-bundle-ID/same-DevID-team updates keep Accessibility + Input Monitoring grants (TCC keys to bundle ID + designated requirement; team/cert or ad-hoc changes break them); gate the updater at four `SPUUpdaterDelegate`/gentle-reminder layers off `LockController.isLocked`, and never `startUpdater()` in ad-hoc dev builds (Sparkle would happily install DevID over ad-hoc and churn TCC) — findings in [research/02-update-safety.md](research/02-update-safety.md).

- [EdDSA keys & appcast bootstrap](issues/03-keys-appcast-bootstrap.md) — keypair in the login keychain ("Private key for signing Sparkle updates", **back it up**); public key `gfglPa8tNtUQSbtG7V3hAgCRN0Ik3fKWjd+CDdTpgGk=` + feed `https://raw.githubusercontent.com/rohmanhm/medusa/main/appcast.xml` baked into Info.plist; `appcast.xml` skeleton at the repo root.
- [Wire the updater into the app](issues/04-wire-updater.md) — `Updater.swift` gates Sparkle on a runtime Developer ID signature check (dev builds stay silent; `MEDUSA_UPDATER_DEV=1` overrides for testing) and implements all four inert-while-locked layers; menu item + Settings → General Updates section wired; build verified (`--self-test` PASS, strict codesign PASS).
- [Teach release.sh to publish the appcast](issues/05-release-appcast.md) — new `scripts/update-appcast.sh` (sign_update + hand-appended item, duplicate-version guard, e2e-tested); release.sh verifies the seal pre-notarization and prints the ordered publish checklist (release asset first, appcast push second).
- [Local end-to-end update proof](issues/07-local-e2e-proof.md) — **the loop is proven on this machine**: old build → scheduled check → download → EdDSA verify → atomic swap → relaunch as the new build, ~5 s, zero clicks; SIGTERM-vs-install-on-quit gotcha documented.

## Not yet specified

- ~~Release-notes presentation~~ — settled in [spec.md](spec.md): `sparkle:releaseNotesLink` → the GitHub release page; rendering eyeballed at the first real update (ticket 06), fallback is an embedded `<description>`.
- ~~Settings surface~~ — settled in [spec.md](spec.md): auto-check toggle + Check Now + last-checked caption; dev builds show a placeholder.

## Out of scope

- Tag-triggered CI release pipeline (GitHub Actions, secrets, ASC API key) — charting decision; future effort.
- DMG migration — zip stays; revisit only if first-install UX becomes a goal.
- Homebrew cask (`medusa-app`, `auto_updates true`, `livecheck :sparkle`) — still deferred with v1's distribution tail.
- Delta updates — the zip is ~2 MB; no benefit.
- Beta/pre-release update channels.
- Intel/universal release builds — unchanged from v1 (Apple Silicon zip; Intel builds from source).
