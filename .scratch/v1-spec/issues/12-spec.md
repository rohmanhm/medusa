# Assemble the v1 spec

Type: task
Status: resolved
Blocked by: 01, 02, 03, 04, 05, 07, 08, 09, 10, 11

## Question

Synthesize every resolved ticket into the build-ready spec at `.scratch/v1-spec/spec.md`: architecture (tap + overlay + auth flow), v1 feature behaviors, permissions onboarding, fail-safe design, tech stack, repo/license setup, and the signing + release + Homebrew pipeline, ending with a v1 release checklist.

The map closes when the human has reviewed the spec and agrees the build route is clear.

## Answer

Superseded by the goal override: instead of a spec document to hand off for building, the map produced the **working v1 app** plus `README.md` (which carries the architecture summary, permissions guide, escape hatches, and how-it-works table that the spec would have held). The four `research/*.md` files remain the deep reference. `06-developer-id` dropped from the blocker list — it gates only signed *distribution*, not the local build this goal targets, and stays deferred. The one thing between here and "closed" is the human on-machine verification (grant permissions → ⌘⇧L → Touch ID unlock), tracked in the map's Not-yet-specified.
