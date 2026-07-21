# Research: Signed OSS distribution pipeline for a macOS menu-bar utility (2026)

Resolves: `.scratch/v1-spec/issues/04-distribution.md`
Researched: 2026-07-20

---

## 1. Developer ID signing + notarization in GitHub Actions

### What Apple requires

- All software distributed outside the Mac App Store with Developer ID must be notarized: "Beginning in macOS 10.15, all software built after June 1, 2019, and distributed with Developer ID must be notarized." ([Apple: Notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution))
- Sign with a **Developer ID Application** certificate specifically — "Don't use a Mac Distribution, ad hoc, Apple Developer, or local development certificate."
- **Hardened Runtime** must be enabled and the signature must include a **secure timestamp** (`codesign --timestamp --options runtime`).
- Notarizable deliverables: macOS apps, non-app bundles, **UDIF disk images**, flat installer packages, and **zip archives**.

### CI secrets handling (certificate)

The canonical pattern is GitHub's own doc ([Installing an Apple certificate on macOS runners](https://docs.github.com/en/actions/guides/installing-an-apple-certificate-on-macos-runners-for-xcode-development)):

1. Export the Developer ID Application cert + key as `.p12`, store as base64 secret: `base64 -i BUILD_CERTIFICATE.p12 | pbcopy` → `BUILD_CERTIFICATE_BASE64`, plus `P12_PASSWORD` and a throwaway `KEYCHAIN_PASSWORD`.
2. In the job, build an ephemeral keychain:
   ```sh
   security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
   security import "$CERTIFICATE_PATH" -P "$P12_PASSWORD" -A -t cert -f pkcs12 -k "$KEYCHAIN_PATH"
   security list-keychain -d user -s "$KEYCHAIN_PATH"
   ```
3. On self-hosted (non-ephemeral) runners, delete the keychain in an `if: ${{ always() }}` cleanup step. GitHub-hosted runners are ephemeral so this is belt-and-braces there.

Ready-made action alternative: `apple-actions/import-codesign-certs`. AltTab does it by hand (see §5).

### CI secrets handling (notarization credentials)

`notarytool` accepts three credential styles ([Apple: Customizing the notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)):

- **App Store Connect API key** (recommended for CI): pass `--key AuthKey_XXXX.p8 --key-id <KEY_ID> --issuer <ISSUER_UUID>`. Store the `.p8` as a base64 secret plus `APP_STORE_CONNECT_KEY_ID` / `APP_STORE_CONNECT_ISSUER_ID`. An API key is not tied to a personal Apple ID password or 2FA state, and can be revoked independently — the professional choice for CI.
- **Apple ID + app-specific password + team ID** (`--apple-id --password --team-id`) — what AltTab uses in CI today.
- **Keychain profile** (`xcrun notarytool store-credentials "profile-name" ...` then `--keychain-profile`) — great locally, awkward in CI.

### Submit + staple flow

```sh
ditto -c -k --keepParent "Medusa.app" "Medusa.zip"      # zip for submission
xcrun notarytool submit Medusa.zip --key ... --key-id ... --issuer ... --wait
xcrun stapler staple "Medusa.app"                        # staple the .app itself
```

Critical stapling rule, quoted from Apple: "While you can notarize a ZIP archive, **you can't staple to it directly**. Instead, run `stapler` against each item that you added to the archive. Then create a new ZIP file containing the stapled items for distribution." Disk images and pkgs *can* be stapled directly (`xcrun stapler staple Medusa.dmg`). Standalone (non-bundle) binaries can be notarized but never stapled.

Use `--wait` so the job blocks until Apple returns `Accepted` (AltTab adds `--timeout 15m` and greps the status, failing the build on anything else).

---

## 2. Artifact format: DMG vs zip; release automation

| | DMG | zip |
|---|---|---|
| Notarizable | yes (submit the .dmg) | yes (submit the .zip) |
| Stapleable | **yes, the container itself** — offline Gatekeeper pass even on first download | no — staple the `.app` inside, then re-zip |
| UX | drag-to-/Applications ritual; brandable background | double-click extract; app lands in ~/Downloads |
| Sparkle | supported | supported |
| Homebrew cask | fine (`Stats.dmg`, `Rectangle<ver>.dmg`) | fine (`AltTab-<ver>.zip`) |
| Tooling | `create-dmg` (sindresorhus, npm) or `dmgbuild` (Python) | `ditto -c -k --keepParent` (built-in) |

Peer split: **Rectangle and Stats ship DMG; AltTab ships zip** (with the stapled app re-zipped). Sparkle explicitly supports "updating from dmg, zip archives, tarballs, Apple Archives … and installer packages" and suggests you "reuse the same archive for distribution of your app on your website as well as Sparkle updates" ([Sparkle docs](https://sparkle-project.org/documentation/)).

**Recommendation for Medusa:** one stapled **DMG** per release, reused for the website link, GitHub Release, Homebrew cask, and the Sparkle enclosure. DMG is the only format where the downloaded container itself carries the ticket.

**Release automation:** tag-triggered (`on: push: tags: ['v*']`) workflow on a `macos-*` runner: xcodebuild archive → codesign (Developer ID, hardened runtime, timestamp) → dmg → `notarytool submit --wait` → `stapler staple` → publish with `softprops/action-gh-release` (what AltTab uses, at `@v3`). AltTab instead releases on every push to master using `semantic-release` + commitlint to compute the version — more automation than a v1 needs; tag-triggered is the simpler, equally professional default.

---

## 3. Homebrew: cask acceptance, notability, and the `medusa` name collision

### Notability thresholds (as of 2026)

The prose page ([Acceptable Casks](https://docs.brew.sh/Acceptable-Casks)) no longer prints numbers — it defers to shared metrics and allows exceptions "when there is substantial, independently verifiable public interest and multiple requests for inclusion." The actual enforced numbers live in `brew audit` ([Homebrew/brew `Library/Homebrew/utils/shared_audits.rb`](https://github.com/Homebrew/brew/blob/master/Library/Homebrew/utils/shared_audits.rb)):

- Rejected as "GitHub repository not notable enough" if **< 30 forks AND < 30 watchers AND < 75 stars**.
- Rejected as "GitHub repository too new" if **< 30 days old**.
- **Self-submitted** PRs (the app author submitting their own cask) get **tripled thresholds: 90 forks / 90 watchers / 225 stars**.
- Forked repositories are rejected ("GitHub fork (not canonical repository)").

Also required: app must not need SIP/Gatekeeper bypass — i.e. **ship signed + notarized before submitting**, or the cask will be rejected in practice.

**Consequence:** start with a self-hosted tap (`rohmanhm/homebrew-tap` → `brew install rohmanhm/tap/medusa`). Graduate to homebrew/cask once past ~225 stars (self-submission) or when a third party submits it at 75+ stars / 30+ days.

### Can a `medusa` cask coexist with the `medusa` formula?

**Mechanically yes, but the token will not survive review as `medusa`.**

- Correction to the ticket's premise: the homebrew-core `medusa` formula is **no longer THC-Medusa/foofus** — as of 2026 it is [crytic/medusa](https://github.com/crytic/medusa), a "Solidity smart contract fuzzer powered by go-ethereum" ([formulae.brew.sh/formula/medusa](https://formulae.brew.sh/formula/medusa), v1.5.1). The collision exists either way; only the collider changed.
- No `medusa` cask exists today ([formulae.brew.sh/cask/medusa](https://formulae.brew.sh/cask/medusa) → 404), so the namespace is technically free, and casks/formulae are separate namespaces.
- However, the [Cask Cookbook](https://docs.brew.sh/Cask-Cookbook) token rules say: "If the result still conflicts with the name of an existing Homebrew/homebrew-core formula, **adjust the name to better describe the difference by e.g. appending `-app`**" — with `appium`/`appium-desktop` and `angband`/`angband-app` as examples. Homebrew has actively retro-renamed such casks: the `wireshark` cask is now [`wireshark-app`](https://formulae.brew.sh/cask/wireshark-app) (page lists "Former tokens: wireshark"); `docker` became `docker-desktop`. See also the deduplication/naming discussion in [Homebrew/homebrew-cask#24239](https://github.com/Homebrew/homebrew-cask/issues/24239).
- The confusion risk is real and documented: with both a formula and cask of the same name, unqualified `brew install medusa` **installs the formula**, printing "Treating medusa as a formula. For the cask, use homebrew/cask/medusa" ([Homebrew discussion #480](https://github.com/orgs/Homebrew/discussions/480)). A user typing `brew install medusa` expecting the menu-bar app would get a contract fuzzer.

**Plan:** in our own tap the token can be plain `medusa` (tap-qualified installs are unambiguous). For homebrew/cask, expect/propose token **`medusa-app`** and document `brew install --cask medusa-app` everywhere. If squatting-style confusion matters for marketing, consider whether the product name itself should differ from a known security tool.

### Maintenance after acceptance

Version bumps are automated: "by default, all new formulae and casks from the Homebrew/core and Homebrew/cask repositories are autobumped" — BrewTestBot checks every 3 hours and opens bump PRs ([Autobump docs](https://docs.brew.sh/Autobump)). Rectangle's cask additionally has a `livecheck` block pointing at its Sparkle feed (`strategy :sparkle`), which is the cleanest pattern when Sparkle is in play.

---

## 4. Update mechanism: Sparkle 2 vs manual check vs `brew upgrade`

### What peers do

- **Rectangle:** Sparkle. `SUFeedURL = https://rectangleapp.com/downloads/updates.xml`, `SUPublicEDKey` baked into [Info.plist](https://github.com/rxhanson/Rectangle/blob/main/Rectangle/Info.plist).
- **AltTab:** Sparkle. Appcast is a **file committed to the repo** ([appcast.xml](https://github.com/lwouis/alt-tab-macos/blob/master/appcast.xml)) served at `https://alt-tab.app/appcast.xml`; CI signs each release with `Sparkle/bin/sign_update -s $SPARKLE_ED_PRIVATE_KEY` ([update_appcast.sh](https://github.com/lwouis/alt-tab-macos/blob/master/scripts/update_appcast.sh)).
- **Stats:** no Sparkle — a **custom in-app updater** that checks `https://api.mac-stats.com` with `https://api.github.com` as fallback and downloads the release DMG ([README](https://github.com/exelban/stats)). More code to own for no real gain.

### Sparkle 2 mechanics ([docs](https://sparkle-project.org/documentation/))

- One-time: `generate_keys` creates an EdDSA keypair ("It will generate a private key and save it in your login Keychain"); embed the public key as `SUPublicEDKey` and the feed URL as `SUFeedURL`; keep `CFBundleVersion` monotonically increasing.
- Per release: `generate_appcast` over a folder of archives auto-signs and emits the appcast (plus delta updates), or do it manually with `sign_update` like AltTab. Export the private key as a CI secret (`SPARKLE_ED_PRIVATE_KEY`).
- Appcast hosting: GitHub-adjacent options are a committed `appcast.xml` served via the project site/GitHub Pages (AltTab pattern) — no separate infra.

### Interplay with Homebrew

All three peer casks declare `auto_updates true` (Rectangle, Stats, AltTab cask files), meaning the app self-updates; `brew upgrade` then skips it unless the user runs `brew upgrade --greedy`. Cookbook definition: "Asserts that the cask artifacts auto-update. Use if 'Check for Updates…' or similar is present in an app menu…" ([Cask Cookbook](https://docs.brew.sh/Cask-Cookbook)).

**Recommendation:** Sparkle 2 (signed appcast, appcast.xml in repo/Pages) as the primary channel; cask declares `auto_updates true`; `brew upgrade` remains a valid secondary path since the cask URL is version-pinned and autobumped. Relying on `brew upgrade` alone is the worst option — most users install from the DMG and would get no updates at all.

---

## 5. Peer pipelines end-to-end

### Rectangle ([rxhanson/Rectangle](https://github.com/rxhanson/Rectangle), ~29.5k stars)

- CI ([build.yml](https://github.com/rxhanson/Rectangle/blob/main/.github/workflows/build.yml)): push/PR on `macos-26`, **unsigned** (`CODE_SIGN_IDENTITY="-"`), packages an unsigned `Rectangle.dmg` as a workflow artifact only. No notarization, no release publishing, no secrets.
- Official releases: built/signed/notarized by the maintainer outside public CI; DMG on GitHub Releases + rectangleapp.com; Sparkle feed on rectangleapp.com.
- Cask ([rectangle.rb](https://github.com/Homebrew/homebrew-cask/blob/master/Casks/r/rectangle.rb)): versioned DMG from GitHub Releases, `auto_updates true`, `livecheck` with `strategy :sparkle` against `updates.xml`. ~111k installs/year.

### Stats ([exelban/stats](https://github.com/exelban/stats))

- CI ([build.yaml](https://github.com/exelban/stats/blob/master/.github/workflows/build.yaml)): single job, `macos-15`, `xcodebuild … archive CODE_SIGNING_ALLOWED=NO`. Compile-check only; signing/notarization/DMG happen out-of-band by the maintainer.
- Distribution: `Stats.dmg` on GitHub Releases; README instructs `brew install stats` (unqualified works because **no formula collides** — exactly the luxury Medusa won't have).
- Updates: custom updater (api.mac-stats.com + GitHub API fallback). Cask ([stats.rb](https://github.com/Homebrew/homebrew-cask/blob/master/Casks/s/stats.rb)): DMG, `auto_updates true`.

### AltTab ([lwouis/alt-tab-macos](https://github.com/lwouis/alt-tab-macos)) — the fully automated reference

- Single pipeline [ci_cd.yml](https://github.com/lwouis/alt-tab-macos/blob/master/.github/workflows/ci_cd.yml): push to master on `macos-15` (Xcode 26.0.1) → commitlint → version determined by `semantic-release` → sign → package → notarize → appcast → release.
- Signing ([setup_ci_master.sh](https://github.com/lwouis/alt-tab-macos/blob/master/scripts/codesign/setup_ci_master.sh)): `$APPLE_P12_CERTIFICATE | base64 --decode > codesign.p12`, imported into a fresh keychain by a helper script.
- Notarization ([package_and_notarize_release.sh](https://github.com/lwouis/alt-tab-macos/blob/master/scripts/package_and_notarize_release.sh)): `ditto -c -k --keepParent` zip → `notarytool submit --apple-id "$APPLE_ID" --password "$APPLE_PASSWORD" --team-id "$APPLE_TEAM_ID" "$zipName" --wait --timeout 15m` → fail unless `Accepted` → `xcrun stapler staple "$appFile"` → **re-zip the stapled app** (the zip-can't-be-stapled workaround from §1).
- Appcast: manual XML item + `sign_update -s $SPARKLE_ED_PRIVATE_KEY`, enclosure URLs point at GitHub Release assets; appcast.xml committed to the repo, served at alt-tab.app.
- Publish: `softprops/action-gh-release@v3`; symbols to AppCenter; website update via repo dispatch. Secrets: `APPLE_ID`, `APPLE_PASSWORD`, `APPLE_TEAM_ID`, `APPLE_P12_CERTIFICATE`, `SPARKLE_ED_PRIVATE_KEY`, tokens.
- Cask ([alt-tab.rb](https://github.com/Homebrew/homebrew-cask/blob/master/Casks/a/alt-tab.rb)): **zip** artifact, `auto_updates true`, `livecheck` against `https://alt-tab.app/appcast.xml`.

**Takeaway:** only AltTab runs signing + notarization in public CI; Rectangle and Stats keep release credentials off CI entirely. Both are legitimate; CI-signed (AltTab-style, but tag-triggered and with an App Store Connect API key instead of Apple ID password) is the more reproducible, bus-factor-friendly setup for Medusa.

---

## Recommended pipeline for Medusa (v1)

1. **Trigger:** tag push `v*`.
2. **Build:** `xcodebuild archive` on `macos-15`, Hardened Runtime on, Developer ID Application identity from an ephemeral keychain (GitHub docs pattern, secrets: `BUILD_CERTIFICATE_BASE64`, `P12_PASSWORD`, `KEYCHAIN_PASSWORD`).
3. **Package:** stapled **DMG** via `create-dmg`.
4. **Notarize:** `xcrun notarytool submit Medusa.dmg --key … --key-id … --issuer … --wait`, then `xcrun stapler staple Medusa.dmg` (secrets: `APP_STORE_CONNECT_KEY_B64`, `APP_STORE_CONNECT_KEY_ID`, `APP_STORE_CONNECT_ISSUER_ID`).
5. **Sparkle 2:** `sign_update` with `SPARKLE_ED_PRIVATE_KEY` secret; append item to committed `appcast.xml` (enclosure = GitHub Release DMG URL); `SUFeedURL` → raw/Pages URL of that file.
6. **Publish:** `softprops/action-gh-release` uploads the DMG.
7. **Homebrew:** private tap `rohmanhm/homebrew-tap` with token `medusa` at launch; submit to homebrew/cask as **`medusa-app`** (`auto_updates true`, `livecheck strategy :sparkle`) once past notability (75+ stars / 30+ days via third party, or 225+ stars self-submitted). All docs must say `brew install --cask …` — plain `brew install medusa` yields crytic's Solidity fuzzer from homebrew-core.

---

## Sources

- Apple — Notarizing macOS software before distribution: https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution
- Apple — Customizing the notarization workflow: https://developer.apple.com/documentation/security/customizing-the-notarization-workflow
- GitHub Docs — Installing an Apple certificate on macOS runners: https://docs.github.com/en/actions/guides/installing-an-apple-certificate-on-macos-runners-for-xcode-development
- Homebrew — Acceptable Casks: https://docs.brew.sh/Acceptable-Casks
- Homebrew — audit notability thresholds (shared_audits.rb): https://github.com/Homebrew/brew/blob/master/Library/Homebrew/utils/shared_audits.rb
- Homebrew — Cask Cookbook (token rules, auto_updates): https://docs.brew.sh/Cask-Cookbook
- Homebrew — Autobump: https://docs.brew.sh/Autobump
- Homebrew — formula/cask ambiguity behavior: https://github.com/orgs/Homebrew/discussions/480
- Homebrew — cask/formula naming dedup discussion: https://github.com/Homebrew/homebrew-cask/issues/24239
- formulae.brew.sh — medusa formula (crytic): https://formulae.brew.sh/formula/medusa
- formulae.brew.sh — wireshark-app (former token wireshark): https://formulae.brew.sh/cask/wireshark-app
- Sparkle 2 documentation: https://sparkle-project.org/documentation/
- Rectangle: https://github.com/rxhanson/Rectangle — build.yml, Info.plist; cask: https://github.com/Homebrew/homebrew-cask/blob/master/Casks/r/rectangle.rb
- Stats: https://github.com/exelban/stats — build.yaml, README; cask: https://github.com/Homebrew/homebrew-cask/blob/master/Casks/s/stats.rb
- AltTab: https://github.com/lwouis/alt-tab-macos — ci_cd.yml, scripts/codesign/setup_ci_master.sh, scripts/package_and_notarize_release.sh, scripts/update_appcast.sh, appcast.xml; cask: https://github.com/Homebrew/homebrew-cask/blob/master/Casks/a/alt-tab.rb
