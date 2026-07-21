# Teach release.sh to publish the appcast

Type: task
Status: resolved
Blocked by: 01, 03

## Question

Extend the local release pipeline so every release feeds the updater:

- After notarize/staple/re-zip: `sign_update` the zip with the EdDSA key from the keychain; emit/append the `appcast.xml` item (version = `CFBundleVersion` from the built app, short version = `MEDUSA_VERSION`, enclosure URL = the GitHub Release asset URL pattern `https://github.com/rohmanhm/medusa/releases/download/v<version>/Medusa-<version>.zip`, `sparkle:edSignature`, length).
- `generate_appcast` over an archive folder vs hand-appending an item like AltTab — pick per ticket 01's tooling findings.
- **Ordering**: the enclosure URL must be live before the appcast goes public — sequence is `gh release create` first, commit+push `appcast.xml` after. Decide whether release.sh runs `gh release create` itself now or keeps printing the command; either way it should print a checklist that ends with the appcast push.
- Release-notes presentation (embedded description vs `releaseNotesLink` — see map fog) gets settled here.
- Verification step: appcast XML validates, enclosure URL returns 200, signature verifies against the public key from ticket 03.

## Answer

Done 2026-07-21 (goal-override execution):

- **`scripts/update-appcast.sh`** (new): signs a zip with `sign_update` (EdDSA key from the login keychain, tools from the version-pinned SPM artifact) and inserts a complete `<item>` before `</channel>` — `sparkle:version` (CFBundleVersion), `shortVersionString`, `minimumSystemVersion` 13.0, `releaseNotesLink` → the GitHub release page, enclosure URL defaulting to the GitHub asset pattern. Refuses a duplicate version (idempotency guard). Appcast path and enclosure URL are overridable — the e2e proof exercised the exact same script against a localhost feed.
- **`release.sh`**: an early `codesign --verify --deep --strict` now runs before notarization (catches broken Sparkle seals locally); after staple+re-zip it reads `CFBundleVersion` from the built app and calls `update-appcast.sh`; the output is an **ordered** publish checklist — `gh release create` first (asset must be live), then commit+push `appcast.xml`. The script never runs git itself.
- Hand-append (AltTab-style) chosen over `generate_appcast` — no archive folder to maintain, deterministic output.

## Comments
