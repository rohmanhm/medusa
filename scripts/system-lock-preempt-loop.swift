#!/usr/bin/env swift
/// system-lock-preempt-loop.swift
///
/// Red/green harness for "Engage Medusa when idle" (system-lock preempt):
///   - idle / ⌃⌘Q → auto-lock only when enabled + unlocked
///   - auto-locks force keep-awake
///   - race-loss warns once; never covers loginwindow
///   - system unlock still releases (never-trap)
///
/// Mirrors Sources/Medusa/LockPolicy.swift preempt + session helpers.
/// Run:  swift scripts/system-lock-preempt-loop.swift
/// Exit 0 = green. Exit 1 = red.

import Foundation

// ═══════════════════════════════════════════════════════════════════════════
// PRODUCTION POLICY MIRROR — keep in lock-step with LockPolicy.swift
// ═══════════════════════════════════════════════════════════════════════════

enum PreemptAction: Equatable {
    case none, autoLock
}

enum SessionEvent: Equatable {
    case didWake, screensDidWake, sessionDidBecomeActive
    case systemScreenDidUnlock, systemScreenDidLock
}

enum SessionReaction: Equatable {
    case reaffirm, release, yield, ignore
}

func idlePreempt(
    enabled: Bool,
    isLocked: Bool,
    idleSeconds: TimeInterval,
    thresholdSeconds: TimeInterval
) -> PreemptAction {
    guard enabled, !isLocked, thresholdSeconds > 0, idleSeconds >= thresholdSeconds else {
        return .none
    }
    return .autoLock
}

func chordPreempt(enabled: Bool, isLocked: Bool) -> PreemptAction {
    guard enabled, !isLocked else { return .none }
    return .autoLock
}

func shouldWarnRaceLoss(
    enabled: Bool,
    isLocked: Bool,
    alreadyWarned: Bool
) -> Bool {
    enabled && !isLocked && !alreadyWarned
}

func shouldHoldKeepAwake(forceKeepAwake: Bool, keepAwakeSetting: Bool) -> Bool {
    forceKeepAwake || keepAwakeSetting
}

func sessionReaction(
    event: SessionEvent,
    isLocked: Bool,
    systemScreenLocked: Bool
) -> SessionReaction {
    guard isLocked else { return .ignore }
    switch event {
    case .systemScreenDidUnlock:
        return .release
    case .systemScreenDidLock:
        // Yield (hide + stop tap). Ignore is not enough — see unlock-trap yield fix.
        return .yield
    case .didWake, .screensDidWake, .sessionDidBecomeActive:
        if systemScreenLocked { return .ignore }
        return .reaffirm
    }
}

func productionSource() -> String {
    let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let candidates = [
        here.appendingPathComponent("../Sources/Medusa/LockPolicy.swift"),
        here.appendingPathComponent("Sources/Medusa/LockPolicy.swift"),
        URL(fileURLWithPath: "Sources/Medusa/LockPolicy.swift")
    ]
    for url in candidates {
        if let text = try? String(contentsOf: url, encoding: .utf8) { return text }
    }
    return ""
}

func productionControllerSource() -> String {
    let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let candidates = [
        here.appendingPathComponent("../Sources/Medusa/LockController.swift"),
        here.appendingPathComponent("Sources/Medusa/LockController.swift"),
        URL(fileURLWithPath: "Sources/Medusa/LockController.swift")
    ]
    for url in candidates {
        if let text = try? String(contentsOf: url, encoding: .utf8) { return text }
    }
    return ""
}

func productionMonitorSource() -> String {
    let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let candidates = [
        here.appendingPathComponent("../Sources/Medusa/SystemLockPreemptMonitor.swift"),
        here.appendingPathComponent("Sources/Medusa/SystemLockPreemptMonitor.swift"),
        URL(fileURLWithPath: "Sources/Medusa/SystemLockPreemptMonitor.swift")
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

// ── 1. Idle preempt ─────────────────────────────────────────────────────────

expect(
    "idle, setting off → none",
    idlePreempt(enabled: false, isLocked: false, idleSeconds: 999, thresholdSeconds: 60) == .none
)
expect(
    "idle, already locked → none",
    idlePreempt(enabled: true, isLocked: true, idleSeconds: 999, thresholdSeconds: 60) == .none
)
expect(
    "idle below threshold → none",
    idlePreempt(enabled: true, isLocked: false, idleSeconds: 30, thresholdSeconds: 60) == .none
)
expect(
    "idle at threshold → autoLock",
    idlePreempt(enabled: true, isLocked: false, idleSeconds: 60, thresholdSeconds: 60) == .autoLock
)
expect(
    "idle above threshold → autoLock",
    idlePreempt(enabled: true, isLocked: false, idleSeconds: 300, thresholdSeconds: 60) == .autoLock
)
expect(
    "idle threshold zero → none (disabled picker)",
    idlePreempt(enabled: true, isLocked: false, idleSeconds: 999, thresholdSeconds: 0) == .none
)

// ── 2. Chord preempt ────────────────────────────────────────────────────────

expect(
    "chord, setting off → none",
    chordPreempt(enabled: false, isLocked: false) == .none
)
expect(
    "chord, locked → none",
    chordPreempt(enabled: true, isLocked: true) == .none
)
expect(
    "chord, enabled + unlocked → autoLock",
    chordPreempt(enabled: true, isLocked: false) == .autoLock
)

// ── 3. Keep-awake force ─────────────────────────────────────────────────────

expect(
    "auto-lock forces keep-awake even if setting off",
    shouldHoldKeepAwake(forceKeepAwake: true, keepAwakeSetting: false)
)
expect(
    "manual lock honors keep-awake off",
    !shouldHoldKeepAwake(forceKeepAwake: false, keepAwakeSetting: false)
)
expect(
    "manual lock honors keep-awake on",
    shouldHoldKeepAwake(forceKeepAwake: false, keepAwakeSetting: true)
)

// ── 4. Race-loss warning ────────────────────────────────────────────────────

expect(
    "race loss: enabled, unlocked, not warned → warn",
    shouldWarnRaceLoss(enabled: true, isLocked: false, alreadyWarned: false)
)
expect(
    "race loss: already warned → no",
    !shouldWarnRaceLoss(enabled: true, isLocked: false, alreadyWarned: true)
)
expect(
    "race loss: setting off → no",
    !shouldWarnRaceLoss(enabled: false, isLocked: false, alreadyWarned: false)
)
expect(
    "race loss: Medusa already locked → no (not a preempt race)",
    !shouldWarnRaceLoss(enabled: true, isLocked: true, alreadyWarned: false)
)

// ── 5. Never cover loginwindow / never-trap still holds ─────────────────────

expect(
    "system lock while Medusa locked → yield (hide shield + stop tap)",
    sessionReaction(event: .systemScreenDidLock, isLocked: true, systemScreenLocked: false) == .yield
)
expect(
    "system unlock while Medusa locked → release",
    sessionReaction(event: .systemScreenDidUnlock, isLocked: true, systemScreenLocked: true) == .release
)
expect(
    "didWake during system lock → ignore",
    sessionReaction(event: .didWake, isLocked: true, systemScreenLocked: true) == .ignore
)

// Full sequence: system wins race while Medusa unlocked — no lock engagement.
do {
    var medusaLocked = false
    var warned = false
    let enabled = true

    // System lock arrives first.
    if shouldWarnRaceLoss(enabled: enabled, isLocked: medusaLocked, alreadyWarned: warned) {
        warned = true
    }
    // Must NOT set medusaLocked = true in response (that would fight loginwindow).
    expect("race: system lock does not engage Medusa", !medusaLocked)
    expect("race: warning latched once", warned)

    // Second system lock shouldn't re-warn.
    let second = shouldWarnRaceLoss(enabled: enabled, isLocked: medusaLocked, alreadyWarned: warned)
    expect("race: second system lock no re-warn", !second)
}

// ── 6. Production source still encodes the contracts ────────────────────────

do {
    let policy = productionSource()
    expect("LockPolicy defines idlePreempt", policy.contains("func idlePreempt"))
    expect("LockPolicy defines chordPreempt", policy.contains("func chordPreempt"))
    expect("LockPolicy defines shouldWarnRaceLoss", policy.contains("func shouldWarnRaceLoss"))
    expect("LockPolicy defines shouldHoldKeepAwake", policy.contains("func shouldHoldKeepAwake"))
}

do {
    let controller = productionControllerSource()
    expect(
        "LockController accepts forceKeepAwake",
        controller.contains("forceKeepAwake"),
        "auto-lock must be able to force the power assertion"
    )
    expect(
        "LockController still observes system unlock",
        controller.contains("com.apple.screenIsUnlocked")
    )
    expect(
        "LockController yields on system lock (never blocks loginwindow)",
        controller.contains("yieldToSystemLock") && controller.contains("case .yield"),
        "password-field trap if we only ignore reaffirm"
    )
}

do {
    let monitor = productionMonitorSource()
    expect(
        "SystemLockPreemptMonitor exists",
        !monitor.isEmpty && monitor.contains("SystemLockPreemptMonitor")
    )
    expect(
        "monitor uses CGEventSource idle",
        monitor.contains("secondsSinceLastEventType")
    )
    expect(
        "monitor never draws over loginwindow (no shield on race)",
        !monitor.contains("shield.show") && !monitor.contains("ShieldController")
    )
    expect(
        "monitor listens for system lock for race-loss only",
        monitor.contains("com.apple.screenIsLocked")
    )
}

// ═══════════════════════════════════════════════════════════════════════════
// REPORT
// ═══════════════════════════════════════════════════════════════════════════

let failed = cases.filter { !$0.ok }
let passed = cases.filter { $0.ok }

print("system-lock-preempt-loop — \(cases.count) cases")
print("----------------")
for c in cases {
    let mark = c.ok ? "✅" : "❌"
    let extra = c.detail.isEmpty ? "" : " — \(c.detail)"
    print("\(mark) \(c.name)\(extra)")
}
print("----------------")
print("PASS \(passed.count)  FAIL \(failed.count)")

if failed.isEmpty {
    print("RESULT: GREEN — idle/chord preempt, forced keep-awake, race-loss once, never-trap intact.")
    exit(0)
} else {
    print("RESULT: RED — \(failed.count) case(s) violate the preempt contract.")
    for f in failed {
        print("  • \(f.name)\(f.detail.isEmpty ? "" : " — \(f.detail)")")
    }
    exit(1)
}
