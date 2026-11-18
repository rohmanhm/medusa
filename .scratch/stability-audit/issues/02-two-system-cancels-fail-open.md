# Two system cancels in a row unlock the Mac

Type: research
Status: needs-triage

## Question

`LockController` fails open when LocalAuthentication answers `systemCancel` twice in a row (`wedgeReleaseThreshold = 2`). That is the never-trap rule for a dialog the system cannot present. Can someone standing at the Mac cause two system cancels on purpose?

## What is known

- `LockControllerTests.testTwoSystemCancelsInARowFailOpen` shows the unlock happens.
- The audit did not observe what makes macOS send `systemCancel` to a dialog that is up. Candidates to try: a hot corner that sleeps the display, closing and opening the lid, fast user switching.
- Since this branch, sleep cancels the dialog before the system does (`cancelAuth`), and a reply to a cancelled dialog is dropped. That removes the sleep path if `willSleep` or `screensDidSleep` arrives before the system's own cancel. The order has not been measured.

## What would settle it

Run `--auth-test 60` with the dialog up, try each candidate, and read `auth outcome=` in the log (`log show --predicate 'subsystem == "org.medusa.Medusa.local" AND category == "lock"'`). If any of them yields `cannotPresentNow` twice, require the second cancel to come from a dialog that was presented after a fresh key press, not from the automatic retry.

## Comments
