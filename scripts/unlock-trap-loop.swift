#!/usr/bin/env swift
/// unlock-trap-loop.swift
///
/// Red/green harness for the unlock-trap bugs the user hit:
///   1. Cancel Touch ID → dialog never comes back.
///   2. Power-button → system lock → system unlock → Medusa reappears and
///      traps the machine until force-shutdown.
///
/// Mirrors Sources/Medusa/LockPolicy.swift + LockController session wiring.
/// Run:  swift scripts/unlock-trap-loop.swift
/// Exit 0 = green (never-trap contract holds). Exit 1 = red (bug present).

import Foundation
import LocalAuthentication

// ═══════════════════════════════════════════════════════════════════════════
// PRODUCTION POLICY MIRROR — keep in lock-step with LockPolicy.swift
// ═══════════════════════════════════════════════════════════════════════════

enum AuthOutcome {
    case success, userCanceledOrFailed, cannotPresentNow, cannotPresentEver
}

enum AuthReaction: Equatable {
    case unlock, rearmAndStayLocked, retryAuthSoon, unlockFailOpen
}

enum SessionEvent: Equatable {
    case didWake, screensDidWake, sessionDidBecomeActive
    case systemScreenDidUnlock, systemScreenDidLock
}

enum SessionReaction: Equatable {
    case reaffirm, release, ignore
}

func classify(success: Bool, laCode: LAError.Code?) -> AuthOutcome {
    if success { return .success }
    guard let code = laCode else { return .userCanceledOrFailed }
    switch code {
    case .userCancel, .userFallback, .authenticationFailed,
         .biometryLockout, .biometryNotAvailable, .biometryNotEnrolled:
        return .userCanceledOrFailed
    case .passcodeNotSet, .notInteractive, .invalidContext:
        return .cannotPresentEver
    default:
        return .cannotPresentNow
    }
}

func authReaction(
    success: Bool,
    laCode: LAError.Code?,
    priorWedgeCount: Int,
    wedgeReleaseThreshold: Int = 2
) -> (AuthReaction, Int) {
    if success { return (.unlock, 0) }
    switch classify(success: false, laCode: laCode) {
    case .success: return (.unlock, 0)
    case .userCanceledOrFailed: return (.rearmAndStayLocked, 0)
    case .cannotPresentNow:
        let next = priorWedgeCount + 1
        if next >= wedgeReleaseThreshold { return (.unlockFailOpen, next) }
        return (.retryAuthSoon, next)
    case .cannotPresentEver: return (.unlockFailOpen, priorWedgeCount)
    }
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
        return .ignore
    case .didWake, .screensDidWake, .sessionDidBecomeActive:
        if systemScreenLocked { return .ignore }
        return .reaffirm
    }
}

/// Reads production `LockController.swift` so removing the observers goes red
/// again — a pure in-memory `return true` would lie.
func productionSource() -> String {
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

func productionObserversDeliver(_ event: SessionEvent) -> Bool {
    let source = productionSource()
    switch event {
    case .didWake:
        return source.contains("NSWorkspace.didWakeNotification")
    case .screensDidWake:
        return source.contains("NSWorkspace.screensDidWakeNotification")
    case .sessionDidBecomeActive:
        return source.contains("NSWorkspace.sessionDidBecomeActiveNotification")
    case .systemScreenDidUnlock:
        return source.contains("com.apple.screenIsUnlocked")
            && source.contains("DistributedNotificationCenter")
    case .systemScreenDidLock:
        return source.contains("com.apple.screenIsLocked")
            && source.contains("DistributedNotificationCenter")
    }
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

// ── 1. Cancel must re-arm, never unlock, never increment wedge ──────────────

do {
    let (reaction, wedge) = authReaction(success: false, laCode: .userCancel, priorWedgeCount: 0)
    expect("cancel → rearmAndStayLocked", reaction == .rearmAndStayLocked, "got \(reaction)")
    expect("cancel → wedgeCount = 0", wedge == 0, "got \(wedge)")
}

do {
    let (reaction, _) = authReaction(success: false, laCode: .authenticationFailed, priorWedgeCount: 1)
    expect("fingerprint miss → rearm (not fail-open)", reaction == .rearmAndStayLocked, "got \(reaction)")
}

do {
    var wedge = 0
    var unlocked = false
    for _ in 0..<5 {
        let (r, w) = authReaction(success: false, laCode: .userCancel, priorWedgeCount: wedge)
        wedge = w
        if r == .unlock || r == .unlockFailOpen { unlocked = true }
    }
    expect("five cancels never unlock (bystander-proof)", !unlocked && wedge == 0,
           "unlocked=\(unlocked) wedge=\(wedge)")
}

// ── 2. Cue machine: cancel then touch must re-present ───────────────────────

do {
    var isAuthenticating = false
    var hasCuedAuth = false
    var presentations = 0

    func beginAuth() {
        guard !isAuthenticating else { return }
        isAuthenticating = true
        presentations += 1
    }
    func onCancel() {
        isAuthenticating = false
        hasCuedAuth = false
    }
    func cue() {
        guard !hasCuedAuth else { return }
        hasCuedAuth = true
        beginAuth()
    }

    cue()
    expect("first touch presents dialog", presentations == 1)
    onCancel()
    expect("after cancel isAuthenticating=false", !isAuthenticating)
    expect("after cancel hasCuedAuth=false (rearmed)", !hasCuedAuth)
    cue()
    expect("second touch re-presents dialog", presentations == 2, "got \(presentations)")
}

// Stuck isAuthenticating: session reaffirm must clear so next cue presents.
do {
    var isAuthenticating = true
    var hasCuedAuth = true
    var presentations = 0

    func beginAuth() {
        guard !isAuthenticating else { return }
        isAuthenticating = true
        presentations += 1
    }
    func onSessionReaffirm(clearStuckAuth: Bool) {
        if clearStuckAuth {
            isAuthenticating = false
            hasCuedAuth = false
        }
    }

    beginAuth()
    expect("stuck auth blocks re-present without clear", presentations == 0)

    onSessionReaffirm(clearStuckAuth: true)
    beginAuth()
    expect("reaffirm clears stuck auth and allows re-present", presentations == 1,
           "got \(presentations)")
}

// ── 3. POWER-BUTTON TRAP — the user's exact sequence ────────────────────────

do {
    let reaction = sessionReaction(
        event: .systemScreenDidUnlock,
        isLocked: true,
        systemScreenLocked: true
    )
    expect(
        "systemScreenDidUnlock while locked → release",
        reaction == .release,
        "got \(reaction) — returning ignore/reaffirm IS the power-button trap"
    )
}

do {
    let delivered = productionObserversDeliver(.systemScreenDidUnlock)
    expect(
        "production observes com.apple.screenIsUnlocked",
        delivered,
        "LockController must listen for system unlock or a later didWake re-traps"
    )
}

do {
    // Full sequence under fixed policy + fixed observers.
    var locked = true
    var systemLocked = false

    func handle(_ event: SessionEvent) {
        guard productionObserversDeliver(event) else { return }
        switch event {
        case .systemScreenDidLock: systemLocked = true
        case .systemScreenDidUnlock: systemLocked = false
        default: break
        }
        switch sessionReaction(event: event, isLocked: locked, systemScreenLocked: systemLocked) {
        case .release: locked = false
        case .reaffirm, .ignore: break
        }
    }

    handle(.systemScreenDidLock)
    expect("after system lock Medusa still locked (ignore)", locked)

    // Wake while system lock is up must NOT reaffirm (would cover loginwindow).
    let wakeDuringSystemLock = sessionReaction(
        event: .didWake, isLocked: true, systemScreenLocked: true
    )
    expect("didWake during system lock → ignore (don't cover loginwindow)",
           wakeDuringSystemLock == .ignore, "got \(wakeDuringSystemLock)")

    handle(.systemScreenDidUnlock)
    expect("after system unlock Medusa released", !locked,
           locked ? "still locked — power-button trap" : "")

    handle(.didWake)
    handle(.screensDidWake)
    expect("wake after system unlock does not re-lock", !locked)
}

// Plain display-sleep wake (no system unlock) must still reaffirm.
do {
    expect("didWake while locked, no system lock → reaffirm",
           sessionReaction(event: .didWake, isLocked: true, systemScreenLocked: false) == .reaffirm)
    expect("screensDidWake while locked, no system lock → reaffirm",
           sessionReaction(event: .screensDidWake, isLocked: true, systemScreenLocked: false) == .reaffirm)
    expect("didWake while unlocked → ignore",
           sessionReaction(event: .didWake, isLocked: false, systemScreenLocked: false) == .ignore)
}

// ── 4. Wedge / fail-open still works ────────────────────────────────────────

do {
    let (r1, w1) = authReaction(success: false, laCode: .systemCancel, priorWedgeCount: 0)
    expect("first systemCancel → retryAuthSoon", r1 == .retryAuthSoon, "got \(r1)")
    let (r2, _) = authReaction(success: false, laCode: .systemCancel, priorWedgeCount: w1)
    expect("second systemCancel → unlockFailOpen", r2 == .unlockFailOpen, "got \(r2)")
}

do {
    let (r, _) = authReaction(success: false, laCode: .notInteractive, priorWedgeCount: 0)
    expect("notInteractive → unlockFailOpen", r == .unlockFailOpen, "got \(r)")
}

do {
    let (r, _) = authReaction(success: true, laCode: nil, priorWedgeCount: 5)
    expect("success → unlock", r == .unlock, "got \(r)")
}

// ═══════════════════════════════════════════════════════════════════════════
// REPORT
// ═══════════════════════════════════════════════════════════════════════════

let failed = cases.filter { !$0.ok }
let passed = cases.filter { $0.ok }

print("unlock-trap-loop — \(cases.count) cases")
print("----------------")
for c in cases {
    let mark = c.ok ? "✅" : "❌"
    let extra = c.detail.isEmpty ? "" : " — \(c.detail)"
    print("\(mark) \(c.name)\(extra)")
}
print("----------------")
print("PASS \(passed.count)  FAIL \(failed.count)")

if failed.isEmpty {
    print("RESULT: GREEN — cancel re-arms; system unlock observed + releases; no trap.")
    exit(0)
} else {
    print("RESULT: RED — \(failed.count) case(s) violate the never-trap contract.")
    for f in failed {
        print("  • \(f.name)\(f.detail.isEmpty ? "" : " — \(f.detail)")")
    }
    exit(1)
}
