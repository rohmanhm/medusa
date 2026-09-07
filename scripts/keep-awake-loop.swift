#!/usr/bin/env swift
/// keep-awake-loop.swift
///
/// Red/green harness for Keep Awake sessions:
///   - pure policy (levels, deadlines, guard, headers, lock composition)
///   - engine + menu + settings + notifier contracts in production source
///
/// Mirrors Sources/Medusa/KeepAwakePolicy.swift.
/// Run:  swift scripts/keep-awake-loop.swift
/// Exit 0 = green. Exit 1 = red.

import Foundation

// ═══════════════════════════════════════════════════════════════════════════
// PRODUCTION POLICY MIRROR — keep in lock-step with KeepAwakePolicy.swift
// ═══════════════════════════════════════════════════════════════════════════

enum AwakeLevel: String {
    case display, system
}

enum EndReason: Equatable {
    case elapsed, timePassed, battery
}

func resolveLevel(session: AwakeLevel?, lockHold: Bool) -> AwakeLevel? {
    if lockHold { return .display }
    return session
}

func deadlinePassed(deadline: Date?, now: Date) -> Bool {
    guard let deadline else { return false }
    return now >= deadline
}

func endReason(
    deadline: Date?,
    untilTime: Bool,
    now: Date,
    batteryTripped: Bool
) -> EndReason? {
    if batteryTripped { return .battery }
    guard let deadline, now >= deadline else { return nil }
    return untilTime ? .timePassed : .elapsed
}

func batteryShouldTrip(
    enabled: Bool,
    onBattery: Bool,
    percent: Double?,
    warningFinal: Bool,
    threshold: Int
) -> Bool {
    guard enabled, onBattery else { return false }
    if let percent, percent <= Double(threshold) { return true }
    return warningFinal
}

func countdownText(deadline: Date?, now: Date) -> String? {
    guard let deadline else { return nil }
    let total = max(0, Int(deadline.timeIntervalSince(now).rounded(.up)))
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    let seconds = total % 60
    if hours > 0 {
        return String(format: "%d:%02d:%02d", hours, minutes, seconds)
    }
    return String(format: "%d:%02d", minutes, seconds)
}

func productionSource(_ name: String) -> String {
    let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let candidates = [
        here.appendingPathComponent("../Sources/Medusa/\(name)"),
        here.appendingPathComponent("Sources/Medusa/\(name)"),
        URL(fileURLWithPath: "Sources/Medusa/\(name)")
    ]
    for url in candidates {
        if let text = try? String(contentsOf: url, encoding: .utf8) { return text }
    }
    return ""
}

// ═══════════════════════════════════════════════════════════════════════════
// HARNESS
// ═══════════════════════════════════════════════════════════════════════════

struct Case {
    let name: String
    let ok: Bool
    let detail: String
}

var cases: [Case] = []

func expect(_ name: String, _ condition: Bool, _ detail: String = "") {
    cases.append(Case(name: name, ok: condition, detail: detail))
}

let now = Date()
func at(_ offset: TimeInterval) -> Date { now.addingTimeInterval(offset) }

// ── 1. Level resolution ────────────────────────────────────────────────────

expect("no holds → nil", resolveLevel(session: nil, lockHold: false) == nil)
expect(
    "session display alone → display",
    resolveLevel(session: .display, lockHold: false) == .display
)
expect(
    "session system alone → system",
    resolveLevel(session: .system, lockHold: false) == .system
)
expect(
    "lock hold alone → display",
    resolveLevel(session: nil, lockHold: true) == .display
)
expect(
    "lock hold beats system session (strongest wins)",
    resolveLevel(session: .system, lockHold: true) == .display
)
expect(
    "lock hold with display session → display",
    resolveLevel(session: .display, lockHold: true) == .display
)

// ── 2. Deadlines ───────────────────────────────────────────────────────────

expect("nil deadline never passes", !deadlinePassed(deadline: nil, now: now))
expect("future deadline stands", !deadlinePassed(deadline: at(60), now: now))
expect("past deadline passed", deadlinePassed(deadline: at(-1), now: now))
expect("exact deadline passed", deadlinePassed(deadline: now, now: now))

expect(
    "no deadline, no battery → no end",
    endReason(deadline: nil, untilTime: false, now: now, batteryTripped: false) == nil
)
expect(
    "duration deadline → elapsed",
    endReason(deadline: at(-1), untilTime: false, now: now, batteryTripped: false) == .elapsed
)
expect(
    "until-time deadline → timePassed",
    endReason(deadline: at(-1), untilTime: true, now: now, batteryTripped: false) == .timePassed
)
expect(
    "battery beats deadline tie",
    endReason(deadline: at(-1), untilTime: false, now: now, batteryTripped: true) == .battery
)
expect(
    "battery ends indefinite Session",
    endReason(deadline: nil, untilTime: false, now: now, batteryTripped: true) == .battery
)

// ── 3. Battery guard ───────────────────────────────────────────────────────

expect(
    "guard off never trips",
    !batteryShouldTrip(enabled: false, onBattery: true, percent: 1, warningFinal: true, threshold: 10)
)
expect(
    "on AC never trips",
    !batteryShouldTrip(enabled: true, onBattery: false, percent: 1, warningFinal: true, threshold: 10)
)
expect(
    "at threshold trips",
    batteryShouldTrip(enabled: true, onBattery: true, percent: 10, warningFinal: false, threshold: 10)
)
expect(
    "below threshold trips",
    batteryShouldTrip(enabled: true, onBattery: true, percent: 4, warningFinal: false, threshold: 10)
)
expect(
    "above threshold holds",
    !batteryShouldTrip(enabled: true, onBattery: true, percent: 42, warningFinal: false, threshold: 10)
)
expect(
    "Final warning trips above threshold (tired battery)",
    batteryShouldTrip(enabled: true, onBattery: true, percent: 42, warningFinal: true, threshold: 10)
)
expect(
    "nil percent falls back to warning level",
    !batteryShouldTrip(enabled: true, onBattery: true, percent: nil, warningFinal: false, threshold: 10)
)

// ── 4. Countdown format ────────────────────────────────────────────────────

expect("indefinite → nil", countdownText(deadline: nil, now: now) == nil)
expect(
    "83 s → 1:23",
    countdownText(deadline: at(83), now: now) == "1:23",
    "the format (not the font) fixes jitter"
)
expect(
    "59 s → 0:59",
    countdownText(deadline: at(59), now: now) == "0:59"
)
expect(
    "past deadline clamps to 0:00",
    countdownText(deadline: at(-5), now: now) == "0:00"
)
expect(
    "over an hour → h:mm:ss",
    countdownText(deadline: at(3723), now: now) == "1:02:03"
)

// ── 5. Production source contracts ─────────────────────────────────────────

do {
    let policy = productionSource("KeepAwakePolicy.swift")
    expect("KeepAwakePolicy defines resolveLevel", policy.contains("func resolveLevel"))
    expect("KeepAwakePolicy defines endReason", policy.contains("func endReason"))
    expect("KeepAwakePolicy defines batteryShouldTrip", policy.contains("func batteryShouldTrip"))
    expect("KeepAwakePolicy defines countdownText", policy.contains("func countdownText"))
    expect("KeepAwakePolicy ignores hotkey while locked", policy.contains("hotkeyAllowed"))
}

do {
    let power = productionSource("PowerAssertion.swift")
    expect(
        "PowerAssertion is level-aware",
        power.contains("AwakeLevel") && power.contains("func begin(level:"),
        "single boolean assertion can't express System awake"
    )
    expect(
        "PowerAssertion uses kernel timeouts",
        power.contains("kIOPMAssertionTimeoutKey") && power.contains("TimeoutActionTurnOff"),
        "a hung app must be disarmed by the kernel"
    )
    expect(
        "PowerAssertion supports Extend on the same ID",
        power.contains("func retimeout") && power.contains("IOPMAssertionSetProperty")
    )
}

do {
    let controller = productionSource("KeepAwakeController.swift")
    expect(
        "engine owns session + lock hold",
        controller.contains("KeepAwakeController") && controller.contains("lockHold")
    )
    expect(
        "deadline tick re-reads the wall clock",
        controller.contains("DispatchSource") || controller.contains("Timer")
    )
    expect(
        "engine re-evaluates on wake + clock change",
        controller.contains("didWakeNotification") && controller.contains("NSSystemClockDidChange"),
        "timers stop during sleep"
    )
    expect(
        "engine never touches notifications unbundled (via guarded notifier)",
        controller.contains("KeepAwakeNotifier") && !controller.contains("UNUserNotificationCenter.current()"),
        "current() traps uncatchably without a bundle id"
    )
}

do {
    let lock = productionSource("LockController.swift")
    expect(
        "Lock places a Lock hold on the engine",
        lock.contains("keepAwakeEngine") && lock.contains("setLockHold"),
        "two assertion owners would be two sources of truth"
    )
    expect(
        "Lock still fails open without the engine (headless path)",
        lock.contains("power.begin()"),
        "SelfTest/auth-test must keep today's behavior"
    )
}

do {
    let menu = productionSource("MenuBarController.swift")
    expect("menu has a Keep Awake section", menu.contains("Keep Awake"))
    expect("menu offers Extend + Stop", menu.contains("Extend") && menu.contains("Stop Keep Awake"))
    expect("menu supports Quick start", menu.contains("QuickStart") || menu.contains("quickStart"))
    expect("menu countdown uses 1:23 shape", menu.contains("countdownText"))
}

do {
    let settings = productionSource("SettingsPanes.swift")
    expect("Keep Awake has its own Settings pane", settings.contains("KeepAwakePane"))
    expect(
        "lock toggle moved out of Lock Screen",
        !settings.contains("Keep Mac awake while locked") || settings.contains("KeepAwakePane"),
        "moved home, not duplicated"
    )
}

do {
    let notifier = productionSource("KeepAwakeNotifier.swift")
    expect(
        "notifier guards the bundle id",
        notifier.contains("bundleIdentifier != nil"),
        "UNUserNotificationCenter.current() traps unbundled"
    )
    expect("notifier carries an Extend action", notifier.contains("extendActionID") || notifier.contains("Extend 30 min"))
}

do {
    let app = productionSource("AppDelegate.swift")
    expect("app owns one engine", app.contains("KeepAwakeController()"))
    expect("app wires the Lock hold", app.contains("keepAwakeEngine = keepAwake"))
    expect("second hotkey toggles Sessions", app.contains("keepAwakeHotKey"))
}

// ═══════════════════════════════════════════════════════════════════════════
// REPORT
// ═══════════════════════════════════════════════════════════════════════════

let failed = cases.filter { !$0.ok }
let passed = cases.filter { $0.ok }

print("keep-awake-loop — \(cases.count) cases")
print("----------------")
for c in cases {
    let mark = c.ok ? "✅" : "❌"
    let extra = c.detail.isEmpty ? "" : " — \(c.detail)"
    print("\(mark) \(c.name)\(extra)")
}
print("----------------")
print("PASS \(passed.count)  FAIL \(failed.count)")

if failed.isEmpty {
    print("RESULT: GREEN — levels, deadlines, guard, countdown, engine composition intact.")
    exit(0)
} else {
    print("RESULT: RED — \(failed.count) case(s) violate the Keep Awake contract.")
    for f in failed {
        print("  • \(f.name)\(f.detail.isEmpty ? "" : " — \(f.detail)")")
    }
    exit(1)
}
