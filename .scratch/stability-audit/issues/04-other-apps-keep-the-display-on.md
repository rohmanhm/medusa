# Other apps keep the display on

Type: task
Status: needs-triage

## Question

"My screen sometimes does not sleep" is partly not Medusa. Should the Keep Awake menu say who else is keeping the Mac awake?

## Evidence

From `pmset -g log` on 2026-11-17: Medusa released its assertion at 02:08:50 and held none until 07:05:20, and the display stayed on throughout. The holders were:

- Dia: `NoDisplaySleepAssertion "Capturing"`, summarized every 15 minutes through the night.
- `coreaudiod`: `com.apple.audio.context….preventuseridledisplaysleep`, released at 04:47:26 after 118 hours.

## Sketch

`IOPMCopyAssertionsByProcess` returns every assertion by pid, with no permission needed. One disabled line in the Keep Awake menu, built when the menu opens: "Also kept awake by: Dia, coreaudiod". It names the cause and does nothing else.

## Comments
