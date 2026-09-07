# Detecting "while an app or process is running" — feasibility for Medusa's audience

Type: research
Status: resolved
Blocked by: None — can start immediately

## Question

Amphetamine offers "keep awake while <app> is running" for GUI apps. Medusa's users leave **CLI** work running: `claude`, `codex`, `xcodebuild`, `swift build`, `ffmpeg`, `python train.py`. A CLI-aware End condition would be a genuine edge over Amphetamine — [ticket 05](05-while-running-in-v1.md) decides whether it ships in v1, and needs facts first. From Apple docs, headers (`libproc.h`, `sys/sysctl.h`, `NSWorkspace`, `NSRunningApplication`) and reputable source (e.g. how `htop`/`procps`-style tools or Activity Monitor-alikes list processes on macOS):

1. **GUI apps**: `NSWorkspace.shared.runningApplications` + KVO or `didTerminateApplicationNotification` — reliability, cost, whether it sees agent/background apps and other users' sessions.
2. **CLI processes**: `proc_listpids` / `proc_pidpath` / `proc_name` (libproc — public? stable? used from Swift without a bridging header via SwiftPM?), vs `sysctl(KERN_PROC_ALL)`, vs shelling out to `pgrep`. Which see processes in other terminals/tmux, and what needs no extra permission for a non-sandboxed app.
3. **Matching**: by executable name vs full path vs argv (a Node-based CLI shows up as `node` — how does today's `claude` binary appear? `codex`?). Child-process trees (Terminal → zsh → claude): match any depth?
4. **Polling**: a sane cadence (2–5 s?) and cost for listing ~500 PIDs; a grace period so a process that restarts (build loop) doesn't end the Session.
5. **Picker UX facts**: how to enumerate candidates for a picker (running GUI apps via `NSWorkspace`; running CLI processes de-duplicated by name; a free-text name field).

Deliver in `../research/04-process-detection.md`: a recommended mechanism for GUI and for CLI, a rough size estimate (can GUI-only fit one implementation ticket? does CLI fit a second?), and the risks (false "still running" positives keeping a Mac awake forever — how the Battery guard and an optional max-duration cap mitigate). Cite every claim.

## Answer

Both halves are feasible and cheap. Findings: [`../research/04-process-detection.md`](../research/04-process-detection.md).

1. **GUI** — `NSWorkspaceDidTerminateApplicationNotification` on `NSWorkspace.shared.notificationCenter`, matched on `bundleIdentifier`, KVO on `runningApplications` as backup. No polling (the header says so outright), no permission, 0.094 ms if ever read. Sees agent apps (79 `.accessory` + 54 `.prohibited` vs 10 `.regular` here) so the picker filters to `.regular`; blind to other login sessions and to every CLI process.
2. **CLI** — one `sysctl(KERN_PROC_ALL)` (0.229 ms for 925 procs, carries pid/ppid/uid/`p_comm`/start time) plus selective `sysctl(KERN_PROCARGS2)` for argv. Whole sweep **3.15 ms median**. libproc is public and needs no bridging header (`Darwin.modulemap` L112 makes it an `import Darwin` submodule) but exposes no argv, so it can't be primary; `pgrep` costs ~17 ms and a fork per tick — rejected. Argv is readable for own-uid processes only (657/657 vs 0/200), which is the right boundary, and sees every terminal/tmux/ssh alike. No entitlement, no TCC prompt — re-verified with a hardened-runtime-signed binary.
3. **Matching — argv, never the name.** `claude` is a native Mach-O binary whose executable is named after its *version*: `proc_name`/`p_comm` return `2.1.261`, `proc_pidpath` returns `.../versions/2.1.261`; only `argv[0]` is `claude`. `python -m …` hides its identity in `argv[1:]`, and one `swift build` pid renamed itself `swift`→`swift-frontend`→`swift-package` mid-life. So: case-insensitive substring over joined argv, re-evaluated every tick, never cached against a pid. `codex` isn't installed here — untested, which is itself the argument for argv. Child trees: skip — the flat sweep already matches at any depth, and `proc_listchildpids` under-reported (2 of 10 children).
4. **Cadence 5 s** (0.06 % duty cycle), **30 s grace** on disappearance via the free `p_starttime`, plus arm-on-first-sighting so a not-yet-running target doesn't end the Session instantly.
5. **Picker** — GUI: 10 rows. CLI: filtering system/app-bundle paths and de-duping by argv name cut 652 own-uid processes to **26 distinct names** (`claude ×8` among them); sort by newest start time, plus a free-text field.

**Size**: GUI fits one implementation ticket comfortably (smaller than `SystemLockPreemptMonitor`); CLI fits a second at ~1.5× that. Neither touches `Package.swift`.

**Top risk**: a loose pattern (`python`, `node ×18`) matching something immortal and keeping a plugged-in Mac awake forever. Battery guard only covers laptops, so this needs a **mandatory max-duration cap** (default on, 4 h) plus a live match count in the menu — both new product surface for the spec.
