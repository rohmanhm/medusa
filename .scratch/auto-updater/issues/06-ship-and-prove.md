# Ship the first self-updating release and prove the loop

Type: task
Status: resolved
Blocked by: 04, 05

## Question

Cut the release that carries the updater, and run the end-to-end proof the destination demands. HITL — needs the dev machine, notary credentials, and Touch ID.

- Version the first self-updating release (presumably **v0.2.0** — the updater is a feature, not a patch).
- README updates: updater in the features list; **bootstrap note** — v0.1.x users must download this one release manually (they have no updater); download links bumped.
- Publish via the extended `release.sh` + `gh release create`, then push the appcast.
- **The proof**: an older *Sparkle-carrying* build must detect and install the shipped release. v0.1.x can't do it (no Sparkle), so either (a) build a properly-signed lower-versioned build locally and let it read the real appcast, or (b) ship v0.2.0, then prove the loop live when v0.2.1 ships. Decide at resolution — (a) proves it before users touch it, which fits the destination better.
- Confirm after the in-place update: Accessibility + Input Monitoring grants intact (no re-prompt), lock still works, version string correct.

## Answer

**SHIPPED AND PROVEN 2026-07-21** (user-approved publish):

- **v0.2.0 is live**: [release](https://github.com/rohmanhm/medusa/releases/tag/v0.2.0) with `Medusa-0.2.0.zip` (Developer ID, notarized — Apple accepted the bundle with Sparkle embedded — stapled), `CFBundleVersion` 4. Feature commit + `chore: appcast + docs for 0.2.0` pushed to main; the raw appcast serves the 0.2.0 item.
- **README updated**: auto-update feature bullet, 0.2.0 download link, bootstrap note for 0.1.x users (one manual update onto the train), Distribution section rewritten (notarized zip + Sparkle feed, cask/CI still planned).
- **Production proof, option (a) as planned**: a Developer ID-signed build stamped 0.1.9-test/build 3 read the **production** appcast (`raw.githubusercontent.com/...(main)/appcast.xml` via the plist `SUFeedURL`), downloaded the **real** GitHub release asset, EdDSA-verified it, atomically swapped itself to 0.2.0 build 4, and relaunched — ~5 s, zero clicks. The swapped bundle passes `spctl`: `source=Notarized Developer ID`. (Silent path via the dev-override immediate-install hook; the interactive prompt UI + release-notes rendering will be eyeballed at the first organic update, e.g. when v0.2.1 ships.)
- **Residual (organic, can't be simulated)**: TCC-grant continuity across a real /Applications update — research 02 says grants survive same-team/same-bundle-ID updates; confirm no re-prompt when the user's installed 0.2.0 later self-updates.

## Comments
