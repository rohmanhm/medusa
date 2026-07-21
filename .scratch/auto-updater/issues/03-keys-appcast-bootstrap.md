# EdDSA keys & appcast bootstrap

Type: task
Status: resolved
Blocked by: 01

## Question

One-time Sparkle infrastructure, done once the integration research fixes the tooling:

- Generate the EdDSA keypair with Sparkle's `generate_keys` (private key lands in the login keychain — same custody model as the notary credentials; record where it lives and the backup story, since losing it orphans every shipped build).
- Settle the appcast's committed path (repo root `appcast.xml` vs `docs/`) and its public **`SUFeedURL`** (raw.githubusercontent.com vs GitHub Pages — pick for stability and Content-Type behavior per research findings).
- Bake `SUPublicEDKey` + `SUFeedURL` into `Resources/Info.plist` (the template `build-app.sh` copies).
- Record the public key and feed URL in the resolution so later tickets and future releases can verify against them.

## Answer

Done 2026-07-21 (goal-override execution):

- **Keypair**: generated with `generate_keys` (Sparkle 2.9.4, from the SPM artifact at `.build/artifacts/sparkle/Sparkle/bin/`). Private key lives in the **login keychain** as "Private key for signing Sparkle updates" — same custody model as the notary credentials. **Back it up** (`generate_keys -x file`); losing it orphans every shipped build. Rotation rule: rotate the Apple cert *or* the EdDSA keys in one update, never both.
- **Public key**: `gfglPa8tNtUQSbtG7V3hAgCRN0Ik3fKWjd+CDdTpgGk=` — baked into `Resources/Info.plist` as `SUPublicEDKey`.
- **Feed**: `appcast.xml` committed at the repo root, served as `https://raw.githubusercontent.com/rohmanhm/medusa/main/appcast.xml` — baked in as `SUFeedURL`. raw.githubusercontent serves `text/plain`, which Sparkle parses fine (it doesn't require an XML content type).
- `SUVerifyUpdateBeforeExtraction` left unset (per spec: keeps dev/e2e flows simple; optional hardening later).

## Comments
