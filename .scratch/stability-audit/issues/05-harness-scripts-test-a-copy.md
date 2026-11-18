# The harness scripts test a copy of the policy

Type: task
Status: needs-triage

## Question

`scripts/unlock-trap-loop.swift`, `scripts/system-lock-preempt-loop.swift` and `scripts/keep-awake-loop.swift` each carry a hand-written mirror of the policy functions and assert on the mirror. Their other checks search the production source for a word. Should they move into `Tests/MedusaTests`, which calls the production code?

## Evidence

- The countdown never showed in 0.3.0 and 0.3.1, and the check "menu countdown uses 1:23 shape" passed, because it only searched `MenuBarController.swift` for `countdownText`.
- This branch changed `KeepAwakePolicy.resolveLevel`, `LockPolicy.sessionReaction` and the Session model. All three scripts stayed green without an edit to their mirrors.
- Four source-text checks were deleted on this branch when the code they named was replaced. `LockControllerTests` and `KeepAwakeEngineTests` cover the behavior.

## Scope

141 checks across the three scripts. The decision tables port one to one. The source-text checks have no behavior to port and can go.

## Comments
