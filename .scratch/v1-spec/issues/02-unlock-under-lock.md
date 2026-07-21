# Unlocking while input is blocked

Type: research
Status: resolved

## Question

The riskiest unknown in the whole app: how can Touch ID / password authentication run while our own CGEvent tap is swallowing every keystroke and click?

- Does `LAContext.evaluatePolicy` present its system dialog in a way that receives input independently of a session-level event tap? (SecurityAgent runs as a separate process — do its events bypass the tap?)
- If the tap does starve the auth dialog: what patterns work — temporarily disabling the tap during auth, allowlisting events targeted at the auth UI, or building a custom password field validated via `LAContext`/OpenDirectory?
- `.deviceOwnerAuthentication` vs `.deviceOwnerAuthenticationWithBiometrics`: fallback-to-password behavior, retry limits, lockout after repeated failures.
- Edge cases: Macs without Touch ID, clamshell mode with external keyboard (Touch ID on Magic Keyboard?), Apple Watch unlock availability.
- How screen-locker peers handle this (any OSS lockers to learn from).

Findings file: `.scratch/v1-spec/research/02-unlock-under-lock.md`

## Answer

Unlock-under-lock is viable; the risk is confined to mouse clicks. Three input paths behave differently:

1. **Touch ID / Apple Watch never traverse the event pipeline** (SEP → biometrickitd → coreauthd, not CGEvents) — a tap can't block them, ever.
2. **Password typing in the system auth dialog is routed AROUND all event taps** by Secure Event Input (Apple TN2150: keyboard events stop flowing to intercept processes — filtering taps included — whenever any process enables secure input, which every system password field does). Our tap cannot starve the field.
3. **Mouse clicks get no such protection** — a click-swallowing tap makes "Use Password…"/"Cancel" unclickable. This is the only real starvation gap.

Pattern: keep the keyboard/scroll block active during auth; stop swallowing mouse events while `evaluatePolicy` is in flight (shield overlay absorbs strays) — proven by OSS peer Lockpaw. Handle `tapDisabledByTimeout`/`ByUserInput` by re-enabling the tap. Use `.deviceOwnerAuthentication` (free password fallback for non-Touch ID Macs, Apple Watch in parallel, covers 5-failure biometry lockout); never gate UX on `canEvaluatePolicy` (DTS-confirmed clamshell/Magic Keyboard bug). Escalation options if needed: `LAAuthenticationView` embedded in our overlay (macOS 12+) or own `NSSecureTextField` + `ODRecord.verifyPassword`. Dialog-vs-shield z-order and in-dialog retry counts need a half-day empirical spike (plan in findings §6).

Full findings: [`.scratch/v1-spec/research/02-unlock-under-lock.md`](../research/02-unlock-under-lock.md)
