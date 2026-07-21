# Signed OSS distribution pipeline

Type: research
Status: resolved

## Question

What does a professional signed-and-notarized OSS release pipeline look like for a macOS utility in 2026?

- Developer ID signing + notarization in GitHub Actions: `codesign`/`xcodebuild` + `notarytool` flow, secrets handling (cert + App Store Connect API key in CI), stapling.
- Artifact format: DMG vs zip for a menu-bar utility; release automation (e.g., tag-triggered).
- Homebrew: cask acceptance criteria for `homebrew/cask` (notability — GitHub stars/age thresholds as of 2026) vs starting with a self-hosted tap. Note: homebrew-core already has a `medusa` **formula** (THC-Medusa, a password brute-forcer); the **cask** namespace is free — confirm a `medusa` cask is acceptable and document the `brew install --cask medusa` vs `brew install medusa` confusion risk.
- Update mechanism: Sparkle 2 (signed appcasts) vs manual "check for updates" vs relying on `brew upgrade`. What do peers do?
- Study 2–3 peer pipelines end-to-end: Rectangle, Stats, AltTab (all signed OSS mac utilities).

Findings file: `.scratch/v1-spec/research/04-distribution.md`

## Answer

- CI signing: ephemeral keychain from a base64 `.p12` secret (GitHub's documented pattern), Developer ID Application cert, Hardened Runtime + timestamp; notarize with `notarytool submit --wait` using an App Store Connect API key (`--key/--key-id/--issuer`), then `stapler staple`.
- Artifact: ship a stapled **DMG** — a zip can be notarized but never stapled (you must staple the inner .app and re-zip, AltTab-style). Reuse the same DMG for GitHub Release, website, cask, and Sparkle enclosure. Tag-triggered workflow + `softprops/action-gh-release`.
- homebrew/cask notability (enforced by `brew audit`, 2026): rejected below 30 forks / 30 watchers / 75 stars, or repo < 30 days old; thresholds **triple for self-submission** (90/90/225). Start with a self-hosted tap.
- The `medusa` name: homebrew-core's `medusa` formula is now **crytic/medusa** (Solidity fuzzer) — not THC-Medusa anymore — but the collision stands. A cask token may technically coexist, but Cask Cookbook rules require de-conflicting (append `-app`; precedents: `wireshark-app`, `angband-app`, `docker-desktop`). Plan on token **`medusa-app`** in homebrew/cask; plain `brew install medusa` installs the fuzzer formula with only a warning.
- Updates: Sparkle 2 (EdDSA `sign_update`, appcast.xml committed to repo / Pages) is the peer norm — Rectangle and AltTab use it; Stats rolled a custom updater. Cask declares `auto_updates true` (so `brew upgrade` defers unless `--greedy`); BrewTestBot autobumps cask versions every 3h once accepted.
- Peers: only **AltTab** signs + notarizes fully in public CI (Apple ID + app-specific password, P12 secret, semantic-release, zip artifact); Rectangle and Stats run unsigned CI and the maintainers sign releases out-of-band. Model Medusa's pipeline on AltTab, but tag-triggered, API-key auth, DMG artifact.

Full findings with commands, workflow/script citations, and cask sources: [`../research/04-distribution.md`](../research/04-distribution.md)
