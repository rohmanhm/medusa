# Amphetamine feature & defaults audit (parity map)

Type: research
Status: resolved
Blocked by: None — can start immediately

## Question

We are cloning Amphetamine's keep-awake into Medusa **deliberately**, not by memory. Produce an authoritative parity map from primary sources — the developer's site (iffy.app/amphetamine), the App Store listing, the in-app/online user guide, the Amphetamine Enhancer GitHub README (x74353/Amphetamine-Enhancer), and the official support forum/FAQ — of what Amphetamine actually offers and what its **defaults** are:

1. **Session types**: indefinite, timed (which preset durations ship by default? is the list editable?), until a specific time, while an app is running, while a file downloads, while a drive is mounted, others. How **Extend** works during a session.
2. **Session options & defaults**: allow display sleep (default?), allow screen saver, closed-display mode (what it requires), Drive Alive, end session when battery drops below X % (default on? default threshold?), ignore sessions on battery, notifications (start / end / ending-soon lead time), sounds, end-of-session actions if any.
3. **Menu bar UX**: left-click vs right-click behavior, quick-start default duration setting ("Default Duration" — what is it by default?), time remaining shown in the menu bar (default?), icon sets.
4. **Hotkeys**: which exist, shipped defaults (assigned or not).
5. **Triggers**: the full list (for our Out-of-scope section to be precise), and how they interact with manual sessions.
6. **Automation**: AppleScript, Shortcuts, URL scheme.
7. **Safety copy**: how Amphetamine explains lid-closed limits, battery, and "session ended because…" notices — useful wording precedent for Medusa's honest copy.

Deliver in `../research/02-amphetamine-audit.md`: a table (feature · Amphetamine default · Medusa v1 status per the [map](../map.md): in / decide-in-05 / out) and a short list of any Amphetamine default that argues against a charting decision (cite the decision number, e.g. presets in 13, battery threshold in 9, quick-start in 13). Cite every claim; where a source is a forum post rather than official docs, say so.

## Answer

Full parity map: [../research/02-amphetamine-audit.md](../research/02-amphetamine-audit.md) — read from Amphetamine **5.3.2 itself** (installed bundle: `Info.plist`, `Amphetamine.sdef`, `Localizable.strings`, live preference plist) plus the App Store listing and Wayback snapshots of the now login-gated support portal. No secondary sources.

- **Supports** decisions 4 (display kept awake by default; docs describe exactly our two levels), 5 (Amphetamine only sees *apps* — processes need the Enhancer helper; unsandboxed Medusa can beat it), 11 (session header on, status-bar countdown off), 12 (six hot keys, **none** shipped assigned), 8 (start-at-launch off).
- **Default Duration = Indefinitely** confirmed verbatim → decision 13's quick-start is parity.
- **Challenges**: (9) battery guard ships **off** at 10 % → "on" is a Medusa divergence, record it as deliberate; (10) Amphetamine has **no ending-soon warning** and **deleted** manual start/end notifications in v4 — it notifies by default only for sessions the user did *not* start by hand; (13) the preset ladder is **fixed** (5–60 min by 5, 1–12 h, 24 h) + a one-off "Other Time/Until…" sheet — editable presets are a Medusa invention; (6) Amphetamine exposes "Use timer / Use system clock" as a preference — expect the "lost an hour while the lid was shut" complaint and answer it in copy.
- **Free parity idea**: default click mapping is left = menu, **right/⌃-click = quick-start with the Default Duration**.
- **Copy precedent** to steal: `Session duration has elapsed` · `End time (%@) has passed` · `Battery charge is below %li%%` · `Your Mac will sleep on its normal schedule`; the honest three-bullet Closed-Display warning; the "Power Protect is keeping your Mac awake" stuck-assertion alert — the failure decision 15's kernel timeout makes structurally impossible.
- **Automation**: AppleScript only (22 commands); no Shortcuts, no URL scheme. Triggers: 20-odd criteria, all out of v1. One session at a time (Medusa differs by design: one engine, many Holds).

Charting decisions amended in the map: 6, 9, 10, 11, 13 (see map "Charting decisions" and Decisions so far).
