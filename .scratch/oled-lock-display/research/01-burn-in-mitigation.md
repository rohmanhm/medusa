# OLED burn-in mitigation: prior art survey

**Context.** Medusa's lock shield is a full-screen pure-black `NSWindow` per display showing a constraint-centered vertical stack: a live clock (84 pt, `NSFont` weight `.thin`, white at 95% alpha), a date line (17 pt, 50% alpha), an optional message (16 pt, 75% alpha), and a hint line (15 pt, 60% alpha). A power assertion keeps the display lit while locked, so the same pixels can be lit for **hours**. The stack is centered via `centerX`/`centerY` Auto Layout constraints; a 1-second `Timer` already ticks the clock. This survey collects what shipping products and display literature actually do about static-content wear on OLED, with concrete numbers, to ground a burn-in-safe default mechanism.

Sourcing note: every claim below is cited inline. Where a number could **not** be found in a primary source, that is stated explicitly rather than approximated.

---

## Prior art

### 1. OLED TV pixel shift / pixel orbit (LG, Sony, Samsung) + RTINGS measurements

**LG "Screen Shift".** LG's official reliability page describes it as a feature that "moves the screen slightly at regular intervals to preserve image quality" ([lg.com/us/experience-tvs/oled-tv/reliability](https://www.lg.com/us/experience-tvs/oled-tv/reliability)). LG's Hong Kong OLED-reliability page adds: "Screen Shift moves the pixels of the static area" ([lg.com/hk_en/tv/oled-tv/oled-reliability](https://www.lg.com/hk_en/tv/oled-tv/oled-reliability/)). Companion features on the same pages:

- **Logo Luminance Adjustment** — "can detect static logos on the screen and reduce brightness" of the affected areas.
- **Temporal Peak Luminance Control (TPC)** — detects stationary images that "pose a high risk of retention and adjust[s] the pixel luminance accordingly".
- **Automatic screen saver** — activates "if the TV detects that a static image is displayed on screen after approximately two minutes" (LG US reliability page).
- **Pixel Refresher** — automatic short pass at power-off after every 4 cumulative hours of use (LG told RTINGS this takes 7–10 minutes), and a long ~1-hour pass after 2,000 cumulative hours (LG HK page; RTINGS test-setup notes).

LG does **not** publish the shift distance in pixels, the interval, or the movement pattern on any official page found. (Secondary press commonly claims "1–2 px every few minutes"; no manufacturer page confirms this, so treat that figure as unverified.)

**Sony "Pixel shift".** Sony's support article "The image sometimes shifts. (Pixel shift function)" states: "Pixel shift is a function that prevents screen image retention of the TV screen by shifting the image of the TV screen after a certain amount of time elapses," runs automatically when set to On, and "in order to prolong the life of the panel, setting the Pixel shift function to On is recommended" ([sony-asia.com article 00173233](https://www.sony-asia.com/electronics/support/articles/00173233); mirrored at [sony.co.in](https://www.sony.co.in/electronics/support/articles/00173233)). The article's very title concedes the movement is occasionally *visible* ("the image sometimes shifts"). No distance or interval is published. (Direct fetch of Sony pages was blocked; wording above is as indexed from Sony's own pages via search snapshots.) Sony's OLED notes article also lists Panel Refresh and an idle screen saver as companion measures ([article 00173479](https://www.sony-asia.com/electronics/support/televisions-projectors-monitors/xrm-48a90k/articles/00173479)).

**Samsung "Pixel Shift".** Samsung's support page is the most candid about magnitude: "To reduce the possibility of screen burn-in or image retention, Samsung OLED TVs are equipped with a Pixel Shift function," which "moves the pixels of your screen at regular intervals," is "enabled by default," can make "the screen appear to be moving," and — notably — "the edges of the screen may move outside of the screen borders and may not be visible," i.e. the travel is large enough to clip screen edges ([samsung.com support page](https://www.samsung.com/in/support/tv-audio-video/what-to-do-if-your-samsung-oled-tv-screen-shifts-or-if-the-corner-of-your-screen-is-cut-off/)). Menu path: Settings → General & Privacy → **Panel Care** → Pixel Shift. Samsung's OLED-monitor page adds Logo Brightness reduction and an automatic "Screen Optimization" pass after 4+ cumulative hours (10–15 min) ([samsung.com TSG10003240](https://www.samsung.com/us/support/troubleshoot/TSG10003240/)). Exact px distance/interval: **not published**.

**Takeaway from all three:** every OLED TV vendor ships pixel shift **on by default**, pairs it with **luminance reduction of detected static content**, and treats a **screen saver after ~2 minutes of static content** as part of panel care. None publishes exact travel/interval; Samsung's edge-clipping admission shows travel of at least several pixels.

**RTINGS measurements (reputable third-party).** From the [Real-Life OLED Burn-In Test on 6 TVs](https://www.rtings.com/tv/learn/real-life-oled-burn-in-test) (6× LG C7, 5 h on / 1 h off, 4 cycles/day, 'Screen Shift' **enabled on all TVs**):

- "Note that we expect burn-in to depend on a few factors: The total duration of static content. **LG has told us that they expect it to be cumulative**, so static content, which is present for 30 minutes twice a day, is equivalent to one hour of static content once per day."
- "The brightness of the static content. Our **maximum brightness CNN TV has more severe burn-in than our 200 nits brightness CNN TV**."
- "The colors of the static areas. … the **red sub-pixel is the fastest to degrade, followed by blue and then green**" (from their [20/7 burn-in test](https://www.rtings.com/tv/learn/permanent-image-retention-burn-in-lcd-oled)).
- Final findings after >9,000 hours: "we don't expect most people who watch varied content without static areas to experience burn-in issues," while uniformity issues developed on the TVs showing static-HUD content (news logos, sports scoreboards, FIFA 18).

Two conclusions matter for Medusa: (1) degradation is **cumulative and luminance-driven** — how *bright* and how *long* each pixel is lit is what counts, and (2) **pixel shift alone did not prevent logo burn-in** over thousands of hours of bright static content; it spreads the edge wear but does not reduce total emission.

### 2. iPhone StandBy (iOS 17+)

Apple's iPhone User Guide, "Use StandBy to view info at a distance" ([support.apple.com guide iph878d77632](https://support.apple.com/guide/iphone/use-standby-iph878d77632/ios)):

- **Night Mode:** "When Night Mode is turned on for StandBy, the screen adapts to low ambient light at night and displays items with a red tint so that it's not intrusive while you're sleeping."
- **Display sleep policy (non-AOD iPhones):** Settings → StandBy → Display offers "**Automatically**: The display turns off when iPhone isn't in use and the room is dark. **After 20 Seconds**: The display turns off after 20 seconds. **Never**: The display stays on as long as StandBy is on." On Always-On display models "StandBy stays on to show useful information."
- On the iPhone AOD itself ([support.apple.com 102533](https://support.apple.com/en-hk/102533)): the panel "can operate with a refresh rate as low as **1 Hz** with a new low-power mode," the system "dim[s] the entire Lock Screen," and it is on by default on iPhone 14 Pro/15 Pro+.

**Not found in primary sources:** Apple does not document any clock relocation/pixel-shift cadence for StandBy or the iPhone AOD. (Its published mitigation vocabulary is *dimming*, *1 Hz refresh*, and *turning the display off*, not shifting.) Any claim that StandBy "moves the clock every N minutes" is unsourced.

### 3. Apple Watch / iPhone always-on displays (Apple's design guidance)

Apple Support, "Use the Always On feature with your Apple Watch" ([support.apple.com 105074](https://support.apple.com/en-us/105074)):

- "To preserve battery life, the **display dims when your wrist is down**, or by a quick gesture of covering the display with your hand." (No numeric dim level is published.)
- "While your wrist is down, the time and complications on the watch face **update once a minute**." Live-data complications are paused; "If you have Apple Watch Series 10 or later, information … updates more often" (seconds-capable). AOD is on by default on Series 5+.

WatchKit, "Designing your app for the Always On state" ([developer.apple.com](https://developer.apple.com/documentation/watchkit/designing_your_app_for_the_always_on_state)): "the system updates the user interface at a **much lower frequency** than when running in the foreground. It also **dims the watch**." Developers must "pause any animation and show the final state … and **remove any subsecond updates**."

HIG, "Always On" ([developer.apple.com HIG](https://developer.apple.com/design/human-interface-guidelines/always-on)): a device in Always On serves glanceable info "by **dimming the display and minimizing onscreen motion**"; "Keep important content legible and **dim nonessential content**"; "**Maintain a consistent layout.** Avoid making distracting interface changes … aim to make **infrequent, subtle updates**"; "Gracefully transition motion to a resting state; don't stop it instantly."

Apple never uses the words "burn-in" in these documents and publishes no offsets; its AOD strategy as documented is **hardware 1 Hz refresh + aggressive dimming + minute-cadence updates + minimized motion**. (LTPO 1 Hz addresses power; dimming is what addresses emission wear.)

### 4. Android AOSP always-on display — the actual constants (primary source: source code)

**SystemUI burn-in offsets** — [`BurnInHelper.kt`](https://android.googlesource.com/platform/frameworks/base/+/refs/heads/main/packages/SystemUI/src/com/android/systemui/doze/util/BurnInHelper.kt):

```kotlin
private const val MILLIS_PER_MINUTES = 1000 * 60f
private const val BURN_IN_PREVENTION_PERIOD_Y = 521f      // minutes
private const val BURN_IN_PREVENTION_PERIOD_X = 83f       // minutes
private const val BURN_IN_PREVENTION_PERIOD_SCALE = 181f  // minutes
private const val BURN_IN_PREVENTION_PERIOD_PROGRESS = 89f
```

`getBurnInOffset(amplitude, xAxis)` returns a **`zigzag()`** — "a continuous, piecewise linear, periodic zig-zag function" (triangular wave) — of the current time *in minutes*, so the offset advances a tiny step each minute. `getBurnInScale()` additionally oscillates view scale between **0.8 and 1.0** over the 181-minute period. The X and Y periods (83 and 521 min — near-prime, incommensurate) make the 2-D path a Lissajous-like non-repeating sweep of the offset box rather than a fixed orbit.

**Offset amplitudes** — [`SystemUI res/values/dimens.xml`](https://android.googlesource.com/platform/frameworks/base/+/refs/heads/main/packages/SystemUI/res/values/dimens.xml):

| dimen | value |
|---|---|
| `burn_in_prevention_offset_x` | **8 dp** |
| `burn_in_prevention_offset_y` | **50 dp** |
| `burn_in_prevention_offset_y_clock` | **42 dp** |
| `default_burn_in_prevention_offset` | 15 dp |
| `udfps_burn_in_offset_x` / `_y` | 7 px / 20 px |

**Cadence** — [`DozeUi.java`](https://android.googlesource.com/platform/frameworks/base/+/refs/heads/main/packages/SystemUI/src/com/android/systemui/doze/DozeUi.java) schedules the AOD time tick to the **next minute boundary** (`roundToNextMinute(...)`, with `TIME_TICK_DEADLINE_MILLIS = 90 * 1000` as a missed-tick watchdog). The AOD clock's burn-in offset is re-evaluated on this once-per-minute tick.

Effective motion: the X offset traverses 0→8 dp→0 over 83 min and Y 0→50 dp→0 over 521 min, i.e. steps of roughly **0.19 dp/minute on each axis** — far below perception threshold, while the *cumulative* excursion (8 dp × 42–50 dp box) is several times a text stroke width.

**AOSP DeskClock screensaver (Android's "Daydream" clock)** — [`MoveScreensaverRunnable.java` (android-8.1.0_r1)](https://android.googlesource.com/platform/packages/apps/DeskClock/+/refs/tags/android-8.1.0_r1/src/com/android/deskclock/MoveScreensaverRunnable.java) (identical in [community mirror](https://github.com/amirzaidi/DeskClock/blob/master/src/com/android/deskclock/MoveScreensaverRunnable.java)):

- Repositions the clock **once per minute**, aligned to the minute boundary: `addMinuteCallback(this, -FADE_TIME)` with `private static final long FADE_TIME = 3000L;`
- Each move: **fade out over 3 s while scaling to 0.85 → teleport to a uniformly random position** within the content bounds (`getRandomPoint(mContentView.getWidth() - mSaverView.getWidth())`, i.e. `Math.random() * maximum`) → **fade in over 3 s** scaling back to 1.0, with accelerate/decelerate interpolators.

So Android ships **both** patterns: sub-perceptual zigzag drift for the always-on lock clock (minute cadence, ≤8/50 dp), and whole-screen random relocation for the plugged-in nightstand clock (minute cadence, full-screen travel, 3 s crossfade).

### 5. TV standby / screensaver drift clocks

- **LG "Always Ready"** shows an ambient standby clock/weather screen instead of powering fully off ([lg.com Always Ready help](https://www.lg.com/us/support/help-library/lg-tv-how-to-use-the-always-ready-function--20153870949064)); on OLED models the ~2-minute static-content screen saver described in §1 backstops it. LG does not publish drift parameters for the standby clock.
- **Apple TV** ships moving aerial-video screen savers with a configurable "Start After" idle timeout ([support.apple.com 106002](https://support.apple.com/en-us/106002)); the default minutes value is **not stated** in Apple's documentation. tvOS has no static standby clock, so its screensaver strategy is simply "content that always moves."
- **Android Daydream clock** = the DeskClock screensaver in §4: full-screen random relocation every minute with a 3 s fade.
- **DVD-logo-style bounce** (continuous linear motion with edge reflection) is the folk ancestor of drift clocks; no primary spec (travel/velocity) exists to cite — noted here as a pattern, not a source.

### 6. macOS-specific prior art

- **macOS itself** ships no pixel-shift or panel-care service; its native mitigations are display sleep and (inherently moving) screen savers. There is no public AppKit API for burn-in protection — any mitigation is the app's job.
- **Amphetamine** (keep-awake utility): its documented controls are about *allowing display sleep* during keep-awake sessions ([developer support portal](https://iffy.freshdesk.com/support/solutions/articles/48001077199-amphetamine-closed-display-mode), [App Store](https://apps.apple.com/us/app/amphetamine/id937984704?mt=12)). Release notes for v5.3 (as surfaced in the App Store listing) describe forcing the closed built-in display to sleep specifically "to prevent display burn-in" — i.e. its answer to burn-in is *turning pixels off*, not moving them.
- **Fliqlo** (the classic flip-clock screensaver, white-on-black like Medusa): its official feature list includes "**Dim the display**" and "**Reduce the display size**" ([fliqlo.com](https://fliqlo.com/)) — luminance and lit-area reduction. No pixel-shift/burn-in feature is documented by the developer (third-party sites claim "movement," unconfirmed).
- **Padbury Clock**: no burn-in mitigation documented in any official material found.
- Net: on macOS the prior art is thin — dim, shrink, or sleep. Nobody has shipped an AOSP-quality drift for a Mac lock clock, which is exactly the gap Medusa can fill.

### 7. Quantifying luminance → burn-in

- **The scaling law.** Ossila's OLED testing guide (citing Popovic & Aziz, 2002): "the product between the initial luminance (L₀) of the lifetime test and the lifetime obtained (LT₅₀ …) is a constant … **L₀ⁿ · LT₅₀ = K** … where n is an aging acceleration factor," obtained as the slope of the log-log plot, and explicitly used to "predict the lifetimes for lower luminance values" ([ossila.com](https://www.ossila.com/pages/oled-testing-guide)). The same law ("L0^n × t1/2 = constant") appears in the peer-reviewed review *Approaches for Long Lifetime OLEDs* ([PMC7788592](https://pmc.ncbi.nlm.nih.gov/articles/PMC7788592/)).
- **Typical n.** The 2024 review *The Blue Problem: OLED Stability and Degradation Mechanisms* renormalizes lifetimes "according to the Coulombic degradation scaling law with an **acceleration factor of 1.8**" ([ACS JPCL](https://pubs.acs.org/doi/10.1021/acs.jpclett.3c03317)); industry practice has assumed **1.5** (e.g. [US patent 8,502,445](https://image-ppubs.uspto.gov/dirsearch-public/print/downloadPdf/8502445)); DOE stress testing measured up to 2.6 when thermal acceleration is included ([energy.gov OLED stress test report](https://www.energy.gov/sites/prod/files/2018/05/f51/ssl_oled-stresstest_2018.pdf)). Working range: **n ≈ 1.5–2**.
- **What halving luminance buys:** lifetime scales by 2ⁿ — **≈2.8× (n=1.5) to ≈4× (n=2)** slower degradation for a 50% luminance cut. RTINGS' max-brightness vs 200-nit CNN comparison (§1) is the field confirmation.
- **Does pure black + a small lit area genuinely reduce risk?** Yes. Degradation is per-emitter and driven by cumulative drive/emission (the Coulombic law above is per-pixel); an OLED pixel rendering black is *off* and does not age, which is why RTINGS' burn-in appears as logo-shaped ghosts confined to the lit static areas rather than panel-wide damage, and why "burn-in" is really *differential* aging between heavily-used and lightly-used pixels. Neighboring dark pixels don't wear. The corollary: on a pure-black shield, **only the glyph pixels are at risk**, and the risk metric is (per-pixel luminance) × (hours lit at that spot).
- **Gamma footnote for alpha values:** compositing white at alpha *a* over black gives framebuffer value *a*; with the display's ~2.2 gamma the *emitted luminance* is ≈ a^2.2 of full white. So 95% alpha ≈ 89% luminance, 75% ≈ 53%, 60% ≈ 33%, 50% ≈ 22%.

---

## How much does the existing design already mitigate?

| Design fact | Mitigation value |
|---|---|
| **Pure-black background** | Very high. >99% of panel pixels are off and do not age at all (§7). The whole problem is confined to the glyph strokes of four text lines. |
| **Thin weight (84 pt `.thin`)** | Moderate. Stroke width at 84 pt thin is only a few points (~3–5 pt, estimate), so the lit area is small — and, usefully, even a small shift distance fully de-correlates stroke positions. |
| **95% alpha clock** | Marginal. ≈89% of full luminance (gamma-adjusted, §7) — essentially "on". The clock digits are the brightest, largest wear surface. |
| **50/75/60% alpha secondary lines** | Real. Date line at 50% alpha emits ≈22% of full-white luminance → per the L₀ⁿ law its pixels age ~10× slower than full-white would (n≈1.7). Message (≈53%) and hint (≈33%) sit between. |
| **Minute digits change every minute** | Partial. Digit *shapes* vary, but digits share stroke positions (all have roughly the same bounding box and overlapping segments), so wear is only partially decorrelated; the **colon and often the hour digit are static for an hour+**, and the **date/message/hint lines are pixel-identical for the entire lock session** — these, plus the colon, are the true static-logo analogue of RTINGS' CNN test. |
| **Power assertion, hours lit** | This is the aggravator: it recreates exactly the "static content for many hours per day, every day, cumulative" regime RTINGS identifies as the burn-in scenario — albeit at desktop-white ~90% luminance rather than TV-logo HDR peaks. |

Net: the design is already in the best 10% of lock screens (black field, thin dim text), but the *static* elements lit for hours nightly, with zero motion, are precisely the pattern every vendor above ships default-on countermeasures against. Nothing in the current design moves or dims — the two levers all prior art uses.

---

## Mechanism comparison

For an AppKit constraint-centered stack, "implementation weight" assumes mutating the `centerX`/`centerY` constraint constants (or the stack layer's transform) plus alpha animations, driven from the existing 1 s timer.

| Mechanism | Protection strength | User-visible distraction | Implementation weight |
|---|---|---|---|
| **(a) Subtle pixel shift** — AOSP-style zigzag, ≤~50 pt box, recomputed once/minute | Good for *positional* wear: travel ≫ stroke width spreads each stroke's emission over a band ~10× its area. Does **not** reduce total emission — RTINGS shows shift alone fails against bright multi-thousand-hour static content (§1). | None in practice: ~0.2–0.8 pt/min steps are sub-perceptual (LG/Sony/Samsung ship this default-on; AOSP AOD uses it on every phone). | **Low.** Two constants updated on the minute tick; zigzag is ~10 lines of math. |
| **(b) Full-screen slow drift / wander** — DeskClock-style relocation over a large region | Best positional decorrelation (wear spread over the whole screen); still no emission cut. | Noticeable: a teleport+crossfade every minute is visible across a room; on a *lock* screen sudden motion can read as activity/intrusion. Apple's HIG explicitly warns to "maintain a consistent layout" and prefer "infrequent, subtle updates" in always-on contexts (§3). | Low–medium: random target + safe-area clamping + 3 s crossfade; must keep text inside every display's bounds. |
| **(c) Dim-after-grace** — drop luminance after N idle minutes | **Strongest single lever**: attacks the wear driver itself. Halving luminance ⇒ 2.8–4× slower aging (§7), and it protects the *fully static* elements (colon, date, hint) that motion alone never helps. Matches Apple (AOD dims by default), LG TPC/logo dimming, Fliqlo's "dim" feature. | Low: user is absent by definition during the grace period; needs instant un-dim on input so the user never waits. | **Low.** One alpha animation + reuse of existing input/unlock hooks. |
| **(d) Combination: (a) + (c)** — subtle drift always, dim after grace | Multiplicative: emission cut (2.8–4×) × positional spread (~10×) with each mechanism covering the other's blind spot (dimming for static shapes, motion for the bright pre-dim window and the "Never dim" user). This is exactly the vendor playbook: pixel shift **and** static-area luminance reduction ship together on every OLED TV (§1). | Effectively none. | **Low.** Sum of two low-weight mechanisms sharing the existing timer. |

---

## Recommendation

> **FINAL (2026-07-21)** — adopted as the resolution of [ticket 01](../issues/01-burn-in-research.md); implementation ticket 02 builds this directly. Numbers are grounded in the cited prior art and tuned for Mac panel sizes and Medusa's layout; the map's destination already requires eyeballing the motion on the dev machine's OLED before ship, which covers the remaining hardware sanity check.

**Ship (d): always-on subtle drift + dim-after-grace, both default-on.**

1. **Drift (AOSP-style zigzag), always active while locked.**
   - Recompute the offset **once per minute**, on the minute boundary of the existing 1 s clock timer (so any step lands together with the minute-digit change — Apple Watch AOD and Android doze both use minute cadence, §3/§4).
   - Two independent triangular (zigzag) waves with AOSP's incommensurate periods: **period_x = 83 min, period_y = 521 min** (§4) — the path never visibly repeats.
   - Amplitude (max travel box): **x = 32 pt, y = 48 pt**, applied to the stack's `centerX`/`centerY` constraint constants. Rationale: AOSP uses 8×42–50 dp on a ~6″ panel; a Mac is viewed farther away and Medusa's stack is small relative to the screen, so ~1.5–2.5% of a built-in display's 982-pt logical height is still invisible while being ~8–10× the estimated stroke width. Clamp to ≤5% of the smallest display dimension for tiny/huge externals.
   - Per-minute step ≈ 2·32/83 ≈ **0.8 pt on X** and 2·48/521 ≈ **0.2 pt on Y** — animate each step over **1.0 s ease-in-out** (`NSAnimationContext` on the constraint constants); at this magnitude even a hard snap would be sub-perceptual, satisfying HIG's "infrequent, subtle updates" (§3).
   - Optional flourish (skip for v1): AOSP also oscillates scale 0.8–1.0 over 181 min; unnecessary at our amplitudes.

2. **Dim-after-grace, default on.**
   - **Grace period: 10 minutes** from lock or last local input (mouse/key on the lock shield). Rationale: long enough that a user glancing at the clock never sees it dimmed; the multi-hour tail is where virtually all cumulative wear lives (RTINGS: wear is cumulative, §1).
   - **Dim level: multiply all label alphas by 0.5** (clock 0.95 → 0.475, date 0.50 → 0.25, message 0.75 → 0.375) over **2.0 s ease-out**. Gamma-adjusted, that cuts emitted luminance to ~22–25% of the undimmed state (§7), i.e. **≥3× slower wear** for the whole session tail at n≈1.7 — the same lever Apple's AOD dimming and LG's logo dimming use, without making the clock unreadable across a room.
   - **Hide the hint line entirely after grace** (alpha → 0): it is fully static, lowest-value content — HIG: "dim nonessential content" (§3). Restore on input.
   - **Un-dim in ≤0.15 s** on any local input, before the unlock UI responds, so dimming never feels like lag.

3. **Do not ship large-travel wander as the default.** DeskClock-style random relocation (60 s cadence, 3 s crossfade, §4) is the strongest positional spread and a reasonable **opt-in "screensaver mode"** for users who lock overnight on OLED externals (suggested: relocate every **15 min** within the central 60% of the screen, 3 s crossfade). As a default it violates the HIG consistent-layout guidance and makes a lock screen look active.

**Why this combination:** motion alone demonstrably does not stop burn-in on bright long-lived static content (RTINGS' Screen-Shift-enabled CNN TVs, §1), and dimming alone leaves the first 10 minutes and any "Never dim" configuration exposed; together they reproduce the full OLED-TV panel-care playbook (shift + static-area luminance reduction + content that is mostly black) at trivial AppKit cost: two constraint constants and one alpha group driven by the timer Medusa already runs.

---

## Sources

**Manufacturer / primary product documentation**
- LG — OLED TV Reliability (Screen Shift, Logo Luminance Adjustment, 2-min screen saver): https://www.lg.com/us/experience-tvs/oled-tv/reliability
- LG — OLED reliability / image-retention technologies (Screen Shift wording, TPC, Pixel Refresher 4 h & 2,000 h cadences): https://www.lg.com/hk_en/tv/oled-tv/oled-reliability/
- LG — Always Ready function: https://www.lg.com/us/support/help-library/lg-tv-how-to-use-the-always-ready-function--20153870949064
- Sony — "The image sometimes shifts. (Pixel shift function)": https://www.sony-asia.com/electronics/support/articles/00173233 (mirror: https://www.sony.co.in/electronics/support/articles/00173233)
- Sony — "Notes on using OLED TVs (about image retention)": https://www.sony-asia.com/electronics/support/televisions-projectors-monitors/xrm-48a90k/articles/00173479
- Samsung — OLED TV screen shifts / corner cut off (Pixel Shift): https://www.samsung.com/in/support/tv-audio-video/what-to-do-if-your-samsung-oled-tv-screen-shifts-or-if-the-corner-of-your-screen-is-cut-off/
- Samsung — Prevent burn-in on Samsung OLED Monitor: https://www.samsung.com/us/support/troubleshoot/TSG10003240/

**Apple**
- iPhone User Guide — Use StandBy: https://support.apple.com/guide/iphone/use-standby-iph878d77632/ios
- Use Always-On display (iPhone 14 Pro, 1 Hz): https://support.apple.com/en-hk/102533
- Use the Always On feature with your Apple Watch: https://support.apple.com/en-us/105074
- WatchKit — Designing your app for the Always On state: https://developer.apple.com/documentation/watchkit/designing_your_app_for_the_always_on_state
- HIG — Always On: https://developer.apple.com/design/human-interface-guidelines/always-on
- Apple Newsroom — iOS 17 (StandBy): https://www.apple.com/newsroom/2023/06/ios-17-makes-iphone-more-personal-and-intuitive/
- Apple TV screen savers: https://support.apple.com/en-us/106002

**AOSP source (constants)**
- BurnInHelper.kt (zigzag, periods 83/521/181/89 min, scale 0.8–1.0): https://android.googlesource.com/platform/frameworks/base/+/refs/heads/main/packages/SystemUI/src/com/android/systemui/doze/util/BurnInHelper.kt
- SystemUI dimens.xml (burn_in_prevention_offset_x 8 dp, _y 50 dp, _y_clock 42 dp): https://android.googlesource.com/platform/frameworks/base/+/refs/heads/main/packages/SystemUI/res/values/dimens.xml
- DozeUi.java (minute-boundary time tick, 90 s watchdog): https://android.googlesource.com/platform/frameworks/base/+/refs/heads/main/packages/SystemUI/src/com/android/systemui/doze/DozeUi.java
- DeskClock MoveScreensaverRunnable.java (minute cadence, FADE_TIME 3000 ms, random position): https://android.googlesource.com/platform/packages/apps/DeskClock/+/refs/tags/android-8.1.0_r1/src/com/android/deskclock/MoveScreensaverRunnable.java (mirror: https://github.com/amirzaidi/DeskClock/blob/master/src/com/android/deskclock/MoveScreensaverRunnable.java)

**Measurement / literature**
- RTINGS — Real-Life OLED Burn-In Test on 6 TVs: https://www.rtings.com/tv/learn/real-life-oled-burn-in-test
- RTINGS — 20/7 Burn-In Test: https://www.rtings.com/tv/learn/permanent-image-retention-burn-in-lcd-oled
- Ossila — OLED Testing (L₀ⁿ·LT₅₀ = K, Popovic & Aziz 2002): https://www.ossila.com/pages/oled-testing-guide
- Approaches for Long Lifetime OLEDs (scaling law): https://pmc.ncbi.nlm.nih.gov/articles/PMC7788592/
- The Blue Problem: OLED Stability and Degradation Mechanisms (acceleration factor 1.8): https://pubs.acs.org/doi/10.1021/acs.jpclett.3c03317
- US DOE — Stress Testing of OLED Panels and Luminaires: https://www.energy.gov/sites/prod/files/2018/05/f51/ssl_oled-stresstest_2018.pdf
- US Patent 8,502,445 (RGBW OLED, assumed AF 1.5): https://image-ppubs.uspto.gov/dirsearch-public/print/downloadPdf/8502445

**macOS utilities**
- Amphetamine (App Store listing / release notes): https://apps.apple.com/us/app/amphetamine/id937984704?mt=12
- Amphetamine closed-display documentation: https://iffy.freshdesk.com/support/solutions/articles/48001077199-amphetamine-closed-display-mode
- Fliqlo (official features — dim, reduce size): https://fliqlo.com/
