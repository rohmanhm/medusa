# Apple Developer ID provisioning

Type: task
Status: open

## Question

Human-in-the-loop provisioning: confirm an active Apple Developer Program membership and a **Developer ID Application** certificate usable for signing Medusa releases.

Checklist:

- [ ] Apple Developer Program membership active ($99/yr) on the intended Apple ID
- [ ] Developer ID Application certificate created and exportable (Keychain)
- [ ] Team ID recorded (needed for notarization + hardened runtime config)
- [ ] App Store Connect API key created for CI notarization (`notarytool`)
- [ ] Decide where CI secrets will live (GitHub Actions secrets) — actual secrets never in this repo

Resolution records what exists and where (locations, not secrets), for the distribution and spec tickets to reference.
