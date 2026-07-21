# Ship the first self-updating release and prove the loop

Type: task
Status: claimed
Blocked by: 04, 05

## Question

Cut the release that carries the updater, and run the end-to-end proof the destination demands. HITL — needs the dev machine, notary credentials, and Touch ID.

- Version the first self-updating release (presumably **v0.2.0** — the updater is a feature, not a patch).
- README updates: updater in the features list; **bootstrap note** — v0.1.x users must download this one release manually (they have no updater); download links bumped.
- Publish via the extended `release.sh` + `gh release create`, then push the appcast.
- **The proof**: an older *Sparkle-carrying* build must detect and install the shipped release. v0.1.x can't do it (no Sparkle), so either (a) build a properly-signed lower-versioned build locally and let it read the real appcast, or (b) ship v0.2.0, then prove the loop live when v0.2.1 ships. Decide at resolution — (a) proves it before users touch it, which fits the destination better.
- Confirm after the in-place update: Accessibility + Input Monitoring grants intact (no re-prompt), lock still works, version string correct.

## Comments
