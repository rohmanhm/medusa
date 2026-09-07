# Does "while an app/process is running" ship in v1 — and GUI-only or CLI too?

Type: grilling
Status: resolved
Blocked by: 02, 04

## Answer

**Decision: defer "while running" entirely to the first follow-up effort — not in v1, not even GUI-only.**

Rationale (expert call, delegated):
- Research 04 sizes GUI-only as one ticket (smaller than the preempt monitor) but CLI as a second at ~1.5× (process snapshot + pure matcher + harness + 5 s polling + picker + grace + cap + match count). Together that is ~2.5 tickets of distinct risk surface on top of a v1 that already needs engine + Lock-hold migration + menu + Settings tab + notifications + Battery guard + verify + ship.
- The bias line on this ticket says it plainly: if CLI is not one-ticket-sized, ship GUI+CLI as the first follow-up rather than bloating v1. CLI at 1.5× is not one-ticket-sized, and GUI-only without CLI is Amphetamine parity without Medusa's edge (this audience's work is `claude`/`codex`/`xcodebuild`/`ffmpeg`, all CLI) — it would spend a ticket to ship the half nobody asked for, then rework the picker/matching when CLI lands.
- Risk is load-bearing, not polish: research 04 proves name-based matching fails on `claude` itself (versioned-symlink binary reports `p_comm` = `2.1.261`, only `argv[0]` carries identity; `swift build` renames itself mid-life so identity must be re-evaluated per tick) and a loose pattern (`node` matched 18 processes) holds a plugged-in Mac awake forever. The mandatory max-duration cap (default 4 h, on) + live match count in the menu + argv-substring matching + 30 s grace + arm-on-first-sighting are therefore *requirements*, not options — they belong to the follow-up's design, not to v1 scope creep.
- Battery guard combination is settled now so the follow-up has no open question: "while running" combines exactly like the other End conditions (guard ends it on battery like any Session, with the same ended-notification copy).

Follow-up contract (recorded here so the next map starts decided): End condition "while process X runs" = Session with argv-substring match (case-insensitive, own uid, `p_comm` prefilter), 30 s grace (6 missed ticks at 5 s), mandatory max-duration cap default 4 h (on), live match count in the menu header (`Awake · while claude runs · 3 matches`), picker = running GUI apps (bundle id) + deduped CLI names + free text, menu header as shown, Battery guard applies identically.

`CONTEXT.md` needs no change (its End condition entry already lists only indefinitely / for-a-duration / until-a-clock-time). Map updated in Decisions-so-far; the matching fog line is cleared to "deferred to follow-up".

## Question

Charting decision 5 left one End condition undecided: **"while <app/process> is running"**. Decide, using [research 04](../research/04-process-detection.md) (mechanism, cost, risk) and [research 02](../research/02-amphetamine-audit.md) (how Amphetamine scopes it):

- Ship in **v1**, **v1 as GUI-only with CLI later**, or **defer entirely** to a follow-up effort?
- If shipping: the End condition's exact shape in `CONTEXT.md` terms (a Session whose End condition is "while process X is running", with a grace period and an optional max-duration cap so a zombie can't hold the Mac awake indefinitely), what the picker offers (running GUI apps · running CLI names · free text), and what the menu header reads (`Awake · while claude runs`).
- Whether this End condition combines with the Battery guard exactly like the others (it should).
- Two surfaces [research 04](../research/04-process-detection.md) says this End condition **needs** and the charting decisions never mention: a **mandatory max-duration cap** (its recommendation: on by default, 4 h) so a loose pattern can't hold a plugged-in Mac awake forever, and a **live match count** in the menu header (`Awake · while claude runs · 3 matches`). Decide both, and whether matching is argv-substring, argv-token, or glob — research 04 proves name-based matching fails on `claude` itself.

**Delegated** (map Notes): resolve by making the expert call and writing the rationale in `## Answer`; the user reviews Decisions-so-far. Then update `CONTEXT.md` (End condition entry) and the map (Decisions so far; clear the matching fog line) accordingly. Bias: Medusa's edge is exactly this audience's CLI work, but v1 must stay shippable in a handful of tickets — if CLI detection is not one-ticket-sized, ship GUI+CLI as the **first follow-up** rather than bloating v1.
