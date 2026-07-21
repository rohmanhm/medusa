# Local end-to-end update proof

Type: task
Status: resolved
Blocked by: 04, 05

## Question

Prove the whole update loop on this machine, automated, before anything ships — the AFK half of the destination's proof (the interactive, production-appcast half lives in ticket 06):

- Build two app bundles from the working tree with hand-stamped increasing `CFBundleVersion`s (same code, different builds).
- Zip the newer, `sign_update` it with the real EdDSA key.
- Serve a test `appcast.xml` + the zip over `http://localhost`.
- Run the older build with `MEDUSA_UPDATER_DEV=1` + `MEDUSA_FEED_URL` pointing at the test feed, with `SUEnableAutomaticChecks`/`SUAutomaticallyUpdate` defaults enabled so the silent (no-click) pipeline runs: check → download → EdDSA verify → atomic install.
- Assert the on-disk bundle at the install path is the newer build afterward; clean up defaults, processes, and temp dirs.

Success = the swapped bundle's `CFBundleVersion` equals the newer build's, reached with zero manual interaction.

## Answer

**PROVEN 2026-07-21 on this machine.** Two ad-hoc-signed builds (9000 installed, 9001 zipped + EdDSA-signed via the real `update-appcast.sh`), test appcast on `http://localhost:8377`, old build launched with `MEDUSA_UPDATER_DEV=1` + `MEDUSA_FEED_URL`. Within ~5 seconds of launch: scheduled check hit the feed, downloaded the zip, EdDSA-verified it, atomically swapped the installed bundle to build 9001, terminated the old process (exit 0) and relaunched the new one from the swapped path. Zero clicks.

Two findings worth keeping:

- **SIGTERM is not "quit" to Sparkle's install-on-quit** — killing the process bypasses AppKit termination, the staged install is discarded, and the Sparkle cache is cleaned up. This is why the delegate's dev-mode immediate-install hook exists (production installs go through the user's "Install and Relaunch" click, which Sparkle drives itself).
- The EdDSA-only validation path (ad-hoc host → ad-hoc update) works exactly as research 02 predicted — which is also the reminder that nothing but our DevID-signed gate stops a dev build from installing production updates.

Cleanup verified: test processes stopped, localhost server down, all `SU*` test defaults removed from `org.medusa.Medusa` (the user's real app's domain — its own settings untouched), the user's running `/Applications/Medusa.app` never touched.

## Comments
