# Research: Detecting "while an app or process is running"

Date: 2026-09-05
Effort: `.scratch/keep-awake/`
Question: How can Medusa end a Keep Awake **Session** when a chosen **GUI app** or **CLI process** (`claude`, `codex`, `xcodebuild`, `swift build`, `ffmpeg`, `python`) stops running?

Measurement machine: Mac16,7 (Apple M4 Pro, 14 cores), macOS 26.6.2 (25G83), ~920 processes live, 652–657 owned by uid 501. Probes: throwaway Swift binaries in the session scratchpad, compiled with `swiftc -O`, `import Darwin` / `import AppKit` only.

## TL;DR

| Target | Mechanism | Cost (measured) | Verdict |
|---|---|---|---|
| **GUI app** | `NSWorkspace.shared.runningApplications` + `NSWorkspaceDidTerminateApplicationNotification` on `NSWorkspace.shared.notificationCenter`; KVO on the array as the belt-and-braces | **0.094 ms** per read, 143 apps | **Ship.** Event-driven, no polling, no permission. |
| **CLI process** | One `sysctl(KERN_PROC_ALL)` snapshot for pid/ppid/uid/`p_comm`/start time, plus `sysctl(KERN_PROCARGS2)` for **argv** on the few candidates that `p_comm` can't identify | **3.15 ms** median for the whole sweep | **Ship.** No fork, no permission, no entitlement. |
| ~~libproc~~ | `proc_listpids` + `proc_name` + `proc_pidpath` — public, callable from Swift with no bridging header | 0.157 / 1.5 / 3.7 ms | **Reject as the primary.** No argv → cannot identify `claude`. Keep `proc_pidpath` as an optional extra. |
| ~~pgrep~~ | shell out to `/usr/bin/pgrep -f` | **~17 ms** wall per invocation + a fork/exec every tick | **Reject.** 5× the cost, spawns a process, string-parses stdout, no start times. |

**The load-bearing finding:** `claude`'s real executable is named after its *version number*, so **every name-based match fails**. Only argv works. See §3.1.

## 1. GUI apps — `NSWorkspace`

### 1.1 What Apple guarantees

`NSWorkspace.h` (SDK `.../MacOSX.sdk/System/Library/Frameworks/AppKit.framework/Versions/C/Headers/NSWorkspace.h`, L180-184):

> `/// @return An array of NSRunningApplications representing currently running applications.`
> `/// The order of the array is unspecified, but it is stable […]`
> `/// Similar to NSRunningApplication's properties, this property will only change when the main run loop is run in a common mode. Instead of polling, use key-value observing to be notified of changes to this array property.`
> `/// This property is thread safe […] This property is observable through KVO.`

Apple explicitly says **don't poll** — so unlike `SystemLockPreemptMonitor`'s 2 s idle timer, the GUI path is event-driven.

Notifications, same header L285-291:

> `/* In Mac OS X 10.6 and later, all application notifications have the following key in their userInfo. Its value is an instance of NSRunningApplication, representing the affected app. */`
> `APPKIT_EXTERN NSString * const NSWorkspaceApplicationKey`
> `APPKIT_EXTERN NSNotificationName NSWorkspaceDidTerminateApplicationNotification;`

And L33-34 — the registration trap:

> `/* Returns the NSNotificationCenter for this NSWorkspace. All notifications in this header file must be registered on this notification center. If you register on other notification centers, you will not receive the notifications. */`

So: `NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, …)`, read `userInfo[NSWorkspaceApplicationKey] as? NSRunningApplication`, compare `bundleIdentifier`. `NSRunningApplication.h` L65-67 also offers a per-instance path: `terminated` "Indicates that the process is an exited application. This is observable through KVO."

### 1.2 Reliability and scope

`NSRunningApplication.h` L50:

> `NSRunningApplication is a class to manipulate and provide information for a single instance of an application. **Only user applications are tracked; this does not provide information about every process on the system.**`

Confirmed by probe: `NSWorkspace.shared.runningApplications` returned **143** apps, while `sysctl(KERN_PROC_ALL)` in the same second returned **925** processes. Asking `NSRunningApplication(processIdentifier:)` for three live `claude` CLI pids returned **nil** for all three. **NSWorkspace is structurally blind to CLI work** — this is why the feature needs two mechanisms, not one.

Agent/background apps **are** included, and dominate the list:

| `activationPolicy` | Count |
|---|---|
| `.accessory` (LSUIElement / menu-bar) | 79 |
| `.prohibited` (background / agent) | 54 |
| `.regular` (Dock apps) | **10** |

21 of the 143 had a `nil` `bundleIdentifier` (`NSRunningApplication.h` L94-95: nil "if the application does not have an `Info.plist`"). A picker must filter to `.regular` and skip nil-bundle entries, or it shows the user 143 rows of daemons.

**Other login sessions:** not represented. All 143 belonged to uid 501, while sysctl showed 268 processes owned by other uids. That matches "only user applications are tracked". Medusa should not promise cross-session detection.

**Race caveat**, `NSRunningApplication.h` L54:

> `Properties that vary over time are inherently race-prone. […] properties persist until the next turn of the main run loop in a common mode.`

Practical consequence: don't decide on `isTerminated` synchronously in a tight loop; drive off the notification and re-read `runningApplications` on the main run loop. `processIdentifier` is explicitly *not* an identity (L104-105: "Do not rely on this for comparing processes. Use `-isEqual:` instead"), so **key the Hold on `bundleIdentifier`, not pid** — which also survives an app relaunch (see §5).

### 1.3 Cost

0.094 ms per `runningApplications` read (mean of 20). Free. And with KVO/notifications there is no periodic read at all.

## 2. CLI processes — three options compared

### 2.1 libproc — public, and callable from Swift with no bridging header

`libproc.h` lives at `$(xcrun --show-sdk-path)/usr/include/libproc.h`. Every function Medusa would want carries a public availability macro (L92-102):

```c
int proc_listpids(uint32_t type, uint32_t typeinfo, void *buffer, int buffersize) __OSX_AVAILABLE_STARTING(__MAC_10_5, __IPHONE_2_0);
int proc_name(int pid, void * buffer, uint32_t buffersize)                        __OSX_AVAILABLE_STARTING(__MAC_10_5, __IPHONE_2_0);
int proc_pidpath(int pid, void * buffer, uint32_t buffersize)                     __OSX_AVAILABLE_STARTING(__MAC_10_5, __IPHONE_2_0);
int proc_pidinfo(int pid, int flavor, uint64_t arg, void *buffer, int buffersize) __OSX_AVAILABLE_STARTING(__MAC_10_5, __IPHONE_2_0);
```

**Public since 10.5.** And it is a first-class Swift module — `Darwin.modulemap` L112-114:

```
  module libproc {
    header "libproc.h"
    export *
  }
```

Not `explicit`, so plain `import Darwin` (or `import Foundation`) is enough. **No bridging header, no C target, no `Package.swift` change.** Verified: a single-file `swiftc` build calling `proc_listpids` / `proc_name` / `proc_pidpath` with only `import Darwin` compiled and ran.

One paper cut: the macro `PROC_PIDPATHINFO_MAXSIZE` does **not** import (`sys/proc_info.h` L749 defines it as `(4*MAXPATHLEN)`; Swift reports "macro unavailable: structure not supported"). Write `4 * Int(MAXPATHLEN)`. `PROC_ALL_PIDS` and `MAXCOMLEN` import fine.

Measured over 919 pids: `proc_listpids` **0.157 ms**; `proc_name` × 919 **1.535 ms** but only **653 readable**; `proc_pidpath` × 919 **3.657 ms**, **919/919 readable** — including root-owned processes (`proc_name(1)` → nil, `proc_pidpath(1)` → `/sbin/launchd`).

**Why it can't be the primary:** libproc exposes no argv. See §3.1 — without argv, `claude` is invisible.

### 2.2 sysctl `KERN_PROC_ALL` + `KERN_PROCARGS2` — the recommendation

One `sysctl([CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0])` returns a `kinfo_proc` array carrying **pid, ppid, uid, `p_comm`, and start time** in a single syscall. Constants are in `sys/sysctl.h` (L226 `KERN_PROC`, L436 `KERN_PROC_ALL`, L265 `KERN_PROCARGS2`, L220 `KERN_ARGMAX`).

Measured: **0.229 ms** for the whole 925-process table (mean of 5). That is *cheaper than libproc's pid list alone* and it comes with four extra fields.

`KERN_PROCARGS2` gives the exec path and full argv for one pid. Measured across all 657 own-uid processes: **9.83 ms total, 657 ok / 0 failed**. Across 200 other-uid processes: **0 ok / 200 failed** — argv of processes you don't own is not readable without root. That is the right boundary for Medusa: users watch their own work.

Sizing note: both calls need the two-call size dance, and the table can grow between the calls. Over-allocate (probe used `size + size/4`) and tolerate a short read rather than looping.

`p_comm` is truncated to `MAXCOMLEN` = **16** (`sys/param.h` L95; `sys/proc.h` L138 `char p_comm[MAXCOMLEN + 1]`). Observed: `"Claude Helper (R"` (16 chars) via sysctl vs the full `"Claude Helper (Renderer)"` via libproc `proc_name`, because `proc_bsdinfo.pbi_name` is `2 * MAXCOMLEN` (`sys/proc_info.h` L73). **Never exact-match against `p_comm`** — anything over 16 characters is silently cut.

### 2.3 Shelling out to `pgrep` — reject

`man pgrep`: `-f` "Match against full argument lists", `-x` "Require an exact match", `-u`/`-U` restrict by uid, exit status 1 when nothing matched (verified: `pgrep -f zzz_no_such_proc_zzz` → rc=1).

It works, and `pgrep -f claude` did find the CLI. But:

- **~17 ms wall per invocation** (20 iterations in 0.34 s real) vs 3.15 ms for the in-process sweep. `ps -axo pid,comm` was worse at ~29 ms.
- Every tick forks and execs a child from a menu-bar app that is otherwise idle.
- stdout parsing, locale/format risk, and no start times — so no cheap restart/grace detection (§5).
- Regex semantics leak into user-facing config: a user typing `python train.py` gets `.` treated as a wildcard.

No reason to pay that. Reject.

### 2.4 Permissions

**Nothing is required.** No entitlement, no TCC prompt, no Accessibility grant. Verified twice: an unsigned local build, and the same binary re-signed **ad-hoc with the hardened runtime** (`codesign -f -s - -o runtime`, `flags=0x10002(adhoc,runtime)`) — identical results, 921 processes and 654/654 argv reads, no prompt. Medusa is not sandboxed, so the App Sandbox restrictions on `KERN_PROCARGS2` never apply.

These see **every terminal**: a `claude` in Ghostty, a `tmux` pane, an SSH session, a detached `nohup` — the kernel process table has no notion of which terminal owns a process. The observed matches spanned several separate terminal windows.

## 3. Matching strategy — what actually works

### 3.1 `claude` defeats every name-based match

| Source | Value for a live `claude` CLI (pid 7113) |
|---|---|
| `proc_name` (libproc) | `2.1.258` |
| `p_comm` (sysctl) | `2.1.261` / `2.1.260` / `2.1.259` / `2.1.258` |
| `proc_pidpath` | `/Users/rohmanhm/.local/share/claude/versions/2.1.258` |
| exec path via `KERN_PROCARGS2` | `/Users/rohmanhm/.local/bin/claude` |
| **`argv[0]`** | **`claude`** |
| `ps -o comm=` | `claude` |
| `ps -o ucomm=` | `2.1.258` |

`claude` is a **native Mach-O arm64 binary**, not `node` running a script (`file -L $(which claude)` → `Mach-O 64-bit executable arm64`) — so the ticket's "a Node-based CLI shows up as `node`" worry is not the problem here. The actual problem is the install layout: `/Users/rohmanhm/.local/bin/claude` is a **symlink into `~/.local/share/claude/versions/<version>`**, so the executable's *filename is the version number*. `proc_name`, `p_comm`, and `proc_pidpath` all report the version string. Only argv survives — and note `KERN_PROCARGS2`'s exec path preserves the symlink the user invoked (`.../bin/claude`) while `proc_pidpath` resolves through it.

`codex` is **not installed on this machine**, so it was not observed; the design must not depend on any one tool's packaging — which is exactly the argument for argv.

### 3.2 The other tools, observed

| Tool | `proc_name` / `p_comm` | argv |
|---|---|---|
| `ffmpeg` (live, pid 36266) | `ffmpeg` | `ffmpeg -y -f avfoundation …` |
| `python` (live, pid 1436) | `python3.11` | `…/venv/bin/python -m hermes_cli.stderr_timestamp …` |
| `xcodebuild -version` (spawned) | `xcodebuild` | `/usr/bin/xcodebuild -version` |
| `swift build --help` (spawned) | `swift` → `swift-frontend` → `swift-package` | `/usr/bin/swift build --help` |

Two lessons:

- **Python's identity is in `argv[1:]`, not `argv[0]`.** A user watching "the training run" means `train.py`, and only the joined argv contains it.
- **`swift build` renames itself mid-life.** The *same pid 9868* reported `swift`, then `swift-frontend`, then `swift-package` as the `/usr/bin/swift` shim exec'd through the toolchain, with `argv[0]` changing too. So identity must be **re-evaluated every tick, never cached against a pid**, and a matcher must be substring-based — there is never a process literally named `swift build`.

### 3.3 Recommended rule

Match on the **joined argv, case-insensitively, as a substring**, evaluated fresh each tick, restricted to the user's own uid:

1. One `KERN_PROC_ALL` snapshot; keep own-uid rows.
2. Cheap prefilter on `p_comm` (16 chars, free, already in the snapshot).
3. `KERN_PROCARGS2` only for rows `p_comm` can't settle — a version-looking name, a generic interpreter (`node`, `python`, `sh`, `zsh`, `bash`, `ruby`, `perl`), or a `p_comm` at exactly 16 characters (possibly truncated).
4. Substring match the joined argv.

This is what the 3.15 ms figure measures. Substring beats exact-match here because it is the only rule that catches `claude`, `python -m …`, and `swift build` alike — and the false-positive risk it introduces is real, so §7 caps it.

### 3.4 Child-process trees

**Don't need them, and don't use `proc_listchildpids`.** A whole-table snapshot already carries `e_ppid`, so an ancestry walk is pure in-memory work — verified end to end: `claude` → `zsh` → `claude` → `zsh` → `herdr` → `herdr` → `zsh` → `login` → `ghostty` → `launchd` (10 levels).

`proc_listchildpids` under-reported badly: for `Claude` (pid 19910) it returned **2** children while the sysctl snapshot showed **10** rows with `e_ppid == 19910`; for `ghostty` (2914) and a `zsh` (3357) it returned **0** despite both having children in the snapshot. Whatever the cause, it is not a basis for an End condition.

**Product call:** don't offer tree matching in v1. "Terminal → zsh → claude" already matches at *any* depth because the sweep is flat over the whole table — depth is a non-issue. Tree semantics would only matter for "watch this specific invocation and its children", which is a different (and much harder) feature.

## 4. Polling cadence and cost

| Operation | Measured |
|---|---|
| `NSWorkspace.runningApplications` | 0.094 ms |
| `sysctl(KERN_PROC_ALL)`, 925 procs | 0.229 ms (0.342 ms hardened-signed) |
| `proc_listpids`, 919 pids | 0.157 ms |
| `proc_name` × 919 | 1.535 ms (653 readable) |
| `proc_pidpath` × 919 | 3.657 ms (919 readable) |
| `KERN_PROCARGS2` × 657 own-uid | 9.83 ms |
| **Recommended sweep (snapshot + selective argv)** | **3.15 ms median, 4.44 ms max** |
| Worst case (argv for every own-uid pid) | 6.62 ms |
| `pgrep -f claude` shell-out | ~17 ms |
| `ps -axo pid,comm` shell-out | ~29 ms |

**Cadence: 5 s.** At 3.15 ms that is a **0.06 % duty cycle** — under a tenth of a percent of one core, on a machine whose whole point right now is to stay awake. 2 s (mirroring `SystemLockPreemptMonitor.idlePollInterval`) would be 0.16 % and is also fine, but nothing about "did my build finish" needs 2 s resolution, and a Keep Awake Session may run for hours where the existing preempt monitor runs for minutes. Follow the existing `Timer` + `RunLoop.main.add(timer, forMode: .common)` pattern from `SystemLockPreemptMonitor.startIdleTimer()` so the timer survives menu tracking.

Measurement caveat for the record: an early `ps -axo pid | wc -l` returned 31 because a shell hook was filtering piped output. `/bin/ps -axo pid= | wc -l` returned **924**, reconciling with sysctl's 925.

## 5. Grace period for restart loops

`kinfo_proc.kp_proc.p_un.__p_starttime` is in the snapshot already — verified: a `claude` pid reported "started 2026-09-05 10:15:36 +0000 (5s ago)". So restart detection is free, no extra syscall.

Design:

- **Absence must persist**, not merely occur. End the Session only after the match has been missing for a **grace period of 30 s** (6 consecutive misses at 5 s). A `swift build` re-exec'ing through the shim, a `just watch` loop respawning `ffmpeg`, or a crashed-and-restarted `claude` all reappear well inside that window.
- **Never key on pid.** Pids are reused, and §3.2 showed a single pid changing identity three times. Match by rule each tick; use `p_starttime` only to notice that "the same name, a different process" is a *restart* rather than a continuation — which under a persistence rule needs no special handling at all.
- 30 s is a starting value, not a law; expose it only if a user complains. Amphetamine has no equivalent knob to match against.

## 6. Picker enumeration

**GUI half** — straightforward: `NSWorkspace.shared.runningApplications`, filter `activationPolicy == .regular`, drop nil `bundleIdentifier`, sort by `localizedName`, show `icon`. On this machine that is **10 rows** out of 143. Store the `bundleIdentifier`, never the pid.

**CLI half** — the raw table is unusable (652 own-uid processes) but a modest filter makes it a menu. Filtering out `/System/`, `/usr/libexec/`, `/usr/sbin/`, `/Library/Apple/`, `/Applications/`, and anything containing `.app/Contents/`, then de-duplicating by argv-derived display name, produced **26 distinct names**:

```
node ×18   workerd ×18   chrome-devtools-mcp ×8   claude ×8   zsh ×8
just ×4    caffeinate ×3  bash ×2   dotnet ×2   python ×2   turbo ×2
curl ×1    esbuild ×1     ffmpeg ×1  mprocs ×1   opencode ×1  ssh-agent ×1  …
```

`claude ×8` lands correctly — proof the argv-derived name is the right display key. Sort by most-recent `p_starttime` so the thing the user just started is at the top. Offer a **free-text field** alongside, because the process may not be running when the Session is configured (the whole point of "start Keep Awake, then kick off the build").

## 7. Risks

**A Mac kept awake forever by a false match.** This is the real one, and substring matching on argv makes it worse, not better. A user watching `python` matches every Python process on the box, including a daemon that never exits; `node` matched 18 processes here. Mitigations, in order:

1. **Battery guard** (charting decision 9, default on, ≤ 10 % on battery) is the existing floor — a laptop can't be drained flat. It does nothing for a plugged-in desktop.
2. **Optional max-duration cap on "while running" Sessions.** Required, not optional, in the UI: "…but never longer than [4 hours]", default **on**. This is the honest backstop and it costs one picker row.
3. **IOKit assertion timeout** (charting decision 15) already caps a hung Medusa below the OS.
4. **Show the match in the menu** — "Awake · while `claude` runs (3 matching)". A user who sees "(47 matching)" learns immediately that their pattern is too loose; a silent match teaches nothing.
5. **Warn at configuration time** if the pattern currently matches more than a handful of processes.

**Other risks, smaller:**

- **Watching an app that's already gone.** Configuring "while `ffmpeg` runs" when nothing matches must *not* end the Session instantly. Arm on first sighting, or require the process to appear within a startup window (the grace period, reused) before the absence rule engages.
- **Other users' processes are invisible** to argv matching. Fine for the promise as scoped; don't advertise otherwise.
- **`p_comm` truncation at 16 chars** silently breaks exact matching — §2.2. Substring matching sidesteps it.
- **Identity changes mid-life** (§3.2) — re-evaluate every tick, never cache.
- **Interpreter false negatives** in the other direction: a user typing `train.py` matches only if argv is fetched for that pid, so the §3.3 prefilter must include every common interpreter, or fall back to argv-for-all (6.62 ms, still cheap) if the list ever feels fragile.

## 8. Size estimate

**GUI-only fits one implementation ticket, comfortably.** No polling, no new syscalls, no new dependency: a `RunningAppWatcher` (~80 lines) over the workspace notification centre, an `End condition` case, a picker sheet over `runningApplications`, a `KeepAwakePolicy` case, and harness coverage. It is smaller than `SystemLockPreemptMonitor`.

**CLI fits a second ticket, and only just.** New surface: a `ProcessSnapshot` value type over `KERN_PROC_ALL` + `KERN_PROCARGS2` with the two-call size dance and the `4 * Int(MAXPATHLEN)` workaround (~120 lines), a matcher (pure, therefore harness-testable — the repo's `LockPolicy` + `scripts/*-loop.swift` red/green pattern applies cleanly), a 5 s `Timer` monitor mirroring `SystemLockPreemptMonitor`, grace-period state, the filtered picker plus free-text field, the max-duration cap UI, and the match-count line in the menu. Call it 1.5× the GUI ticket. Split it if it grows: snapshot+matcher+harness first, picker UX second.

Both ship without touching `Package.swift`, without an entitlement, and without a TCC prompt.

## 9. Sources

- `$(xcrun --show-sdk-path)/System/Library/Frameworks/AppKit.framework/Versions/C/Headers/NSWorkspace.h` — L33-34 (notification centre), L180-184 (`runningApplications`, KVO, "instead of polling"), L285-291 (`NSWorkspaceApplicationKey`, `…DidTerminateApplicationNotification`).
- `…/AppKit.framework/…/NSRunningApplication.h` — L50 ("Only user applications are tracked"), L54 (race/run-loop policy), L65-67 (`terminated`, KVO), L86-88 (`activationPolicy`), L94-95 (`bundleIdentifier` nil case), L104-107 (`processIdentifier`: "Do not rely on this for comparing processes").
- `$(xcrun --show-sdk-path)/usr/include/libproc.h` — L92-102, public availability `__OSX_AVAILABLE_STARTING(__MAC_10_5, …)`.
- `$(xcrun --show-sdk-path)/usr/include/Darwin.modulemap` — L112-114, `module libproc { header "libproc.h" export * }` (non-explicit ⇒ `import Darwin` suffices).
- `$(xcrun --show-sdk-path)/usr/include/sys/sysctl.h` — L220 `KERN_ARGMAX`, L226 `KERN_PROC`, L265 `KERN_PROCARGS2`, L436 `KERN_PROC_ALL`.
- `$(xcrun --show-sdk-path)/usr/include/sys/param.h` L95 `MAXCOMLEN 16`; `sys/proc.h` L138 `p_comm[MAXCOMLEN + 1]`; `sys/proc_info.h` L72-73 (`pbi_comm[MAXCOMLEN]`, `pbi_name[2 * MAXCOMLEN]`), L749 `PROC_PIDPATHINFO_MAXSIZE (4*MAXPATHLEN)`.
- `man pgrep` — `-f`, `-x`, `-u`/`-U`, EXIT STATUS; local `pgrep -f zzz…` → rc=1.
- Local probes, 2026-09-05 (scratchpad `probe/probe{1..7}.swift`): libproc from Swift with no bridging header; sysctl snapshot + argv timings and permission boundary (657/657 own-uid vs 0/200 other-uid); `claude` identity table; hardened-runtime re-verification; `swift build` mid-life rename; `proc_listchildpids` under-reporting; picker candidate reduction 652 → 26.
- In-repo: `Sources/Medusa/SystemLockPreemptMonitor.swift` (timer + `.common` run-loop mode pattern); `CONTEXT.md` (Session, Hold, End condition, Battery guard); `.scratch/keep-awake/map.md` charting decisions 5, 9, 15.

## Recommendation

**Ship "while an app or process is running" as two End-condition variants behind one picker.**

1. **GUI apps** — `NSWorkspace.shared.notificationCenter` observing `NSWorkspaceDidTerminateApplicationNotification`, matched on `bundleIdentifier`, with a KVO observation of `runningApplications` as the belt-and-braces. No polling, no permission, ~0.1 ms if ever read. Picker = `.regular` apps only.
2. **CLI processes** — a 5 s `Timer` doing one `sysctl(KERN_PROC_ALL)` plus selective `sysctl(KERN_PROCARGS2)`, matching a case-insensitive substring against the **joined argv** of the user's own processes. 3.15 ms per tick. No `pgrep`, no libproc as the primary, no `Package.swift` change, no entitlement, no TCC prompt.
3. **Match argv, never the executable name.** `claude`'s binary is literally named `2.1.261`; `proc_name`, `p_comm`, and `proc_pidpath` all report the version. Name matching would ship a feature that fails on the flagship use case.
4. **30 s grace period** on disappearance, and arm-on-first-sighting so configuring a not-yet-running process doesn't end the Session immediately.
5. **Require a max-duration cap** on this End condition (default on, 4 h), show the live match count in the menu, and warn when a pattern matches many processes. The Battery guard covers laptops; the cap covers everything else.
6. **Skip child-tree matching in v1.** The flat sweep already matches at any depth, and `proc_listchildpids` is demonstrably unreliable.

## Impact on charting decisions

- **Decision 5 (End conditions v1)** — the CLI edge over Amphetamine is real and cheap. Ticket 05 now has its facts: GUI is trivially affordable; CLI costs ~1.5 implementation tickets and needs argv matching, a grace period, and a mandatory duration cap. Nothing here argues for deferring it, but nothing forces it into v1 either — it is a clean, self-contained slice that could equally be 0.3.1.
- **Decision 9 (Battery guard)** — unchanged, but it is now load-bearing for a *second* reason: it is one of only two backstops against a stuck match. It cannot protect a desktop, hence the max-duration cap.
- **Decision 15 (Architecture)** — the matcher is a pure function over a snapshot value type, so it drops straight into the `KeepAwakePolicy` + `scripts/*-loop.swift` red/green pattern. The IOKit assertion timeout already listed there is the third backstop.
- **New, for the spec** — "while running" needs a **mandatory max-duration cap** and a **menu line showing the live match count**. Both are product surface, not just implementation, and neither is in the charting decisions yet.
- **`Package.swift` is untouched.** `import Darwin` reaches `libproc` and `sysctl` alike; no C target, no bridging header, no SwiftPM change.
