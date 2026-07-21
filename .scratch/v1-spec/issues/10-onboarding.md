# Permissions onboarding flow

Type: grilling
Status: resolved
Blocked by: 01

## Question

Design first-run onboarding around the TCC permission(s) ticket 01 identifies:

- Detecting grant state; deep-linking to the right System Settings pane; polling vs relaunch after grant.
- What the app does while permission is missing or gets revoked mid-use — degrade visibly, never lock without the ability to actually block input.
- Copy/tone for asking for Accessibility access: this is the scariest permission on macOS, and we're an unknown OSS app requesting it. Trust cues (link to source, signed binary).

## Answer

`OnboardingWindow.swift`: a Setup window shown on first run and whenever a lock is attempted with a grant missing. It explains — in plain, trust-building language — why an input-blocking app needs both Accessibility and Input Monitoring, shows a live status dot per permission, and deep-links each to its System Settings pane (`x-apple.systempreferences:...Privacy_Accessibility` / `...Privacy_ListenEvent`) while firing the system consent prompt. A 1 s poll flips the dots green and shows "All set" without a relaunch. If permission is revoked mid-use, `lock()`'s fail-open + the pre-lock `allGranted` check route the user back here rather than locking blind.
