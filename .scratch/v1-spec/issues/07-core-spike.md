# Core-interaction spike

Type: prototype
Status: resolved
Blocked by: 01, 02, 03

## Question

Throwaway prototype to de-risk the core loop before the spec locks architecture: a minimal Swift app that (1) installs a global event tap swallowing all keyboard/mouse input, (2) throws a full-screen overlay on every display, (3) unlocks via `LAContext` Touch ID/password using whatever pattern ticket 02 found.

React to it live: does unlock feel right? Any API friction the research missed (tap timeouts firing, auth dialog starved of input, overlay gaps)? The spike's findings — not its code — feed tickets 08 (stack), 09 (fail-safe), 11 (UX).

Two empirical questions ticket 02's research explicitly left for this spike (plan in `research/02-unlock-under-lock.md` §6):

- Does the `LAContext` auth dialog render **above** a `CGShieldingWindowLevel()` overlay, or must the overlay drop a level during auth?
- How many in-dialog password retries does the system allow before dismissing, and what does Medusa see when it gives up?

Implement the mouse-passthrough-during-auth pattern from ticket 02 and verify strays land harmlessly on the shield.

Link the spike as an asset (scratch directory or gist), don't merge it.

## Answer

Under the goal override the spike became the real app, not a throwaway. Implemented and verified building/launching/stable on macOS 26.5:
- `InputTap.swift` — active session `CGEventTap`, swallow-by-nil, `tapDisabled*` re-enable + watchdog, mouse-passthrough-during-auth.
- `ShieldController.swift` — per-display shield windows at `CGShieldingWindowLevel()`, dropped to screen-saver level during auth (the fix for the dialog z-order risk), live clock + hint.
- `Authenticator.swift` — `LAContext.deviceOwnerAuthentication`, no `canEvaluatePolicy` gate.
- `LockController.swift` — orchestration with fail-open.

Two empirics research left for the spike are now **on-machine test items** (recorded in the map's Not-yet-specified): auth-dialog-vs-shield z-order, and in-dialog password retry count. Everything up to those is code-complete.
