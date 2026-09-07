# Eyeball the motion on the real OLED

Type: task
Status: resolved
Blocked by: 02

## Question

HITL: the user locks with the new build on their OLED panel and reacts — is the motion protective enough without being distracting? Checklist for the session driving this:

- Lock for several minutes on the OLED; watch a full shift/drift cycle.
- Confirm the unlock hint remains discoverable (it moves with the stack).
- Confirm behavior during the auth dialog (window drops to screen-saver level) and after display sleep/wake or hot-plug.
- If it fails the eyeball test, adjust parameters (or escalate to a prototype ticket with 2–3 variants) before shipping.

Resolved when the user signs off on the feel.

## Answer

The eyeball happened (2026-07-21) and surfaced one thing worth recording: with the default **drift** style the user reported "the motion and dim didn't work." Investigation (verified with real timers) showed the mechanism is correct — dim fires exactly on the grace boundary (alpha 1.0→0.5), drift steps on the minute — but **drift is sub-perceptual by design** (~1.5pt over 2 min), so watching for it reads as "broken." Two confounders compound it: settings are read once per lock (a mid-lock change doesn't apply to the current lock), and any interaction re-arms the dim grace via `setAuthMode`.

No parameter change was made — the user accepted the feel as-is and directed shipping. Follow-ups the user declined for now but are on the table: make the default motion `wander` (visibly moving), let dim honor a live settings change on the current lock, or bump drift amplitude so it's at least faintly perceptible.
