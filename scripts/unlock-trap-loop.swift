#!/usr/bin/env swift
/// unlock-trap-loop.swift
///
/// Red/green harness for the unlock-trap bugs the user hit:
///   1. Cancel Touch ID → dialog never comes back.
///   2. Power-button → system lock → system unlock → Medusa reappears and
///      traps the machine until force-shutdown.
///   3. System lock while Medusa locked → password field unreachable because
///      Medusa's shield + key-swallowing tap still own the session (yield fix).
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
    case reaffirm, release, yield, ignore
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
        // Must yield (hide shield + stop tap). Plain ignore leaves Medusa on top
        // of loginwindow and blocks the password field.
        return .yield
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

// ── 2. Cue machine: click / Enter always re-presents after cancel ───────────
//
// Production InputTap no longer latches `hasCuedAuth` across attempts — every
// intentional click/keyDown schedules a cue (coalesced per run-loop turn). The
// controller is the only gate (`!isAuthenticating`, `!systemScreenLocked`).

do {
    var isAuthenticating = false
    var systemScreenLocked = false
    var presentations = 0

    func beginAuth() {
        // Mirror LockController.beginAuth gates.
        guard !systemScreenLocked else { return }
        guard !isAuthenticating else { return }
        isAuthenticating = true
        presentations += 1
    }
    func onCancel() {
        isAuthenticating = false
    }
    /// Per-turn coalesce only — next turn always cues again.
    func cue() {
        beginAuth()
    }

    cue()
    expect("first click/Enter presents dialog", presentations == 1)
    // Second cue while dialog is up is a no-op (idempotent), not a latch bug.
    cue()
    expect("cue while dialog up is idempotent", presentations == 1, "got \(presentations)")
    onCancel()
    expect("after cancel isAuthenticating=false", !isAuthenticating)
    cue()
    expect("click/Enter after cancel re-presents dialog", presentations == 2, "got \(presentations)")
    onCancel()
    cue()
    expect("third click/Enter still re-presents (no sticky latch)", presentations == 3,
           "got \(presentations)")
}

// Stuck isAuthenticating: session reaffirm / reset must clear so next cue presents.
do {
    var isAuthenticating = true
    var presentations = 0

    func beginAuth() {
        guard !isAuthenticating else { return }
        isAuthenticating = true
        presentations += 1
    }
    func onSessionReaffirm(clearStuckAuth: Bool) {
        if clearStuckAuth {
            isAuthenticating = false
        }
    }

    beginAuth()
    expect("stuck auth blocks re-present without clear", presentations == 0)

    onSessionReaffirm(clearStuckAuth: true)
    beginAuth()
    expect("reaffirm clears stuck auth and allows re-present", presentations == 1,
           "got \(presentations)")
}

// Never cue Medusa auth over loginwindow (yield state).
do {
    var isAuthenticating = false
    var systemScreenLocked = true
    var presentations = 0

    func beginAuth() {
        guard !systemScreenLocked else { return }
        guard !isAuthenticating else { return }
        isAuthenticating = true
        presentations += 1
    }

    beginAuth()
    expect("no Medusa auth while systemScreenLocked (yielded)", presentations == 0)
    systemScreenLocked = false
    beginAuth()
    expect("auth resumes after system unlock path clears flag", presentations == 1)
}

// Production source: cue is not a sticky latch, Enter is a keyDown cue.
do {
    let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let tapURL = here.appendingPathComponent("../Sources/Medusa/InputTap.swift")
    let controllerURL = here.appendingPathComponent("../Sources/Medusa/LockController.swift")
    let tap = (try? String(contentsOf: tapURL, encoding: .utf8)) ?? ""
    let controller = (try? String(contentsOf: controllerURL, encoding: .utf8)) ?? ""
    // Reject the old sticky field, not the historical mention in a comment.
    let stickyLatch =
        tap.contains("private var hasCuedAuth")
        || tap.contains("var hasCuedAuth")
        || tap.contains("hasCuedAuth = true")
    expect(
        "InputTap has no sticky hasCuedAuth latch",
        !stickyLatch,
        "sticky latch made second Enter a silent no-op"
    )
    expect(
        "InputTap schedules cue on keyDown/click",
        tap.contains("scheduleCue") && tap.contains("isCue"),
        "click/Enter must reach onInteraction"
    )
    expect(
        "beginAuth refuses while systemScreenLocked",
        controller.contains("!systemScreenLocked") || controller.contains("systemScreenLocked else"),
        "must not re-present Medusa auth over loginwindow"
    )
}

// ── 3. POWER-BUTTON / LOGINWINDOW TRAP — the user's exact sequences ─────────

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
    let lockReaction = sessionReaction(
        event: .systemScreenDidLock,
        isLocked: true,
        systemScreenLocked: false
    )
    expect(
        "systemScreenDidLock while locked → yield (not ignore)",
        lockReaction == .yield,
        "got \(lockReaction) — ignore leaves shield+tap over loginwindow password field"
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
    let delivered = productionObserversDeliver(.systemScreenDidLock)
    expect(
        "production observes com.apple.screenIsLocked",
        delivered,
        "without the lock observer we never yield to loginwindow"
    )
}

do {
    // Full sequence under fixed policy + fixed observers.
    var locked = true
    var systemLocked = false
    var shieldUp = true
    var tapActive = true
    var yielded = false

    func handle(_ event: SessionEvent) {
        guard productionObserversDeliver(event) else { return }
        switch event {
        case .systemScreenDidLock: systemLocked = true
        case .systemScreenDidUnlock: systemLocked = false
        default: break
        }
        switch sessionReaction(event: event, isLocked: locked, systemScreenLocked: systemLocked) {
        case .release:
            locked = false
            shieldUp = false
            tapActive = false
            yielded = false
        case .yield:
            // Stay notionally locked, but surrender display + input.
            shieldUp = false
            tapActive = false
            yielded = true
        case .reaffirm:
            // Reaffirm while system-locked would re-trap — must not happen.
            if !systemLocked {
                shieldUp = true
                tapActive = true
                yielded = false
            }
        case .ignore:
            break
        }
    }

    handle(.systemScreenDidLock)
    expect("after system lock Medusa still locked (yield keeps isLocked)", locked)
    expect("after system lock shield is down", !shieldUp,
           "shield still up — blocks loginwindow")
    expect("after system lock tap is stopped", !tapActive,
           "tap still active — can steal password keystrokes")
    expect("after system lock yielded flag set", yielded)

    // Wake while system lock is up must NOT reaffirm (would cover loginwindow).
    let wakeDuringSystemLock = sessionReaction(
        event: .didWake, isLocked: true, systemScreenLocked: true
    )
    expect("didWake during system lock → ignore (don't cover loginwindow)",
           wakeDuringSystemLock == .ignore, "got \(wakeDuringSystemLock)")
    handle(.didWake)
    expect("wake during system lock does not re-raise shield", !shieldUp)
    expect("wake during system lock does not restart tap", !tapActive)

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

// Production source must actually implement yield (policy + controller).
do {
    let controller = productionSource()
    let policyURLCandidates = [
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("../Sources/Medusa/LockPolicy.swift"),
        URL(fileURLWithPath: "Sources/Medusa/LockPolicy.swift")
    ]
    var policy = ""
    for url in policyURLCandidates {
        if let text = try? String(contentsOf: url, encoding: .utf8) {
            policy = text
            break
        }
    }
    expect(
        "LockPolicy SessionReaction includes yield",
        policy.contains("case yield"),
        "policy must distinguish yield from ignore"
    )
    expect(
        "LockPolicy systemScreenDidLock returns yield",
        policy.contains("return .yield"),
        "system lock must map to yield"
    )
    expect(
        "LockController implements yieldToSystemLock",
        controller.contains("yieldToSystemLock"),
        "controller must have an explicit yield path"
    )
    expect(
        "yield stops the input tap",
        controller.contains("tap.stop()"),
        "leaving the tap alive over loginwindow is the password-field trap"
    )
    expect(
        "yield hides the shield",
        controller.contains("shield.hide()"),
        "auth-level alone is not enough — hide completely"
    )
    // Guard against the old bug: handling system lock with only rearm/setAuthMode
    // and no yield reaction.
    expect(
        "controller switches on .yield",
        controller.contains("case .yield"),
        "reaction table must handle yield"
    )
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
    print("RESULT: GREEN — cancel re-arms; system lock yields; system unlock releases; no trap.")
    exit(0)
} else {
    print("RESULT: RED — \(failed.count) case(s) violate the never-trap contract.")
    for f in failed {
        print("  • \(f.name)\(f.detail.isEmpty ? "" : " — \(f.detail)")")
    }
    exit(1)
}
