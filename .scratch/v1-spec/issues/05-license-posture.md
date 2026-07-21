# OSS license & repo posture

Type: grilling
Status: resolved

## Question

Which open-source license, and what kind of open-source project is this?

- License: MIT vs GPLv3 vs Apache-2.0 — weigh "anyone can fork and sell a closed-source competitor from this code" against maximal adoption.
- Posture: contributions-welcome community project vs source-available solo project (issues open, PRs by invitation)?
- Repo hygiene at v1: issue templates, CONTRIBUTING, code of conduct, security policy for an app holding Accessibility permission.
- Who owns the signing identity relative to the community — releases only from the maintainer's Developer ID.

## Answer

**MIT license** (`LICENSE` at repo root), contributions-welcome posture, issues open. The fork-and-sell-a-competitor risk is accepted as the cost of maximal adoption — an input-lock utility isn't a defensible moat, and MIT is the norm for the peer utilities (Rectangle, AltTab). Release signing stays with the maintainer's identity (see ticket 06). Repo hygiene beyond LICENSE + README (CONTRIBUTING, security policy) is post-v1 polish, not a v1 blocker.
