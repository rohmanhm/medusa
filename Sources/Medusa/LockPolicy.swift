import Foundation
import LocalAuthentication

/// Pure decision surface for the lock lifecycle.
///
/// Extracted so the cancel / wake / system-unlock recovery rules can be
/// exercised without Touch ID, a real event tap, or a shield window. Production
/// `LockController` must call through these helpers — if a recovery rule lives
/// only in the controller, the harness can't go red on it.
enum LockPolicy {
    /// What the controller should do after one `evaluatePolicy` attempt.
    enum AuthReaction: Equatable {
        /// Authenticated — drop the lock.
        case unlock
        /// Human backed out or biometry missed. Stay locked, re-arm the cue so
        /// the next key/click re-presents the dialog.
        case rearmAndStayLocked
        /// System took the dialog away once. Retry auth shortly.
        case retryAuthSoon
        /// Dialog is genuinely unpresentable. Fail open.
        case unlockFailOpen
    }

    /// Session / power / system-lock events that can fire while Medusa is held.
    enum SessionEvent: Equatable {
        case didWake
        case screensDidWake
        case sessionDidBecomeActive
        /// macOS's own lock screen was dismissed (Touch ID / password / power
        /// button unlock). Distributed notification: `com.apple.screenIsUnlocked`.
        case systemScreenDidUnlock
        /// macOS's own lock screen appeared. `com.apple.screenIsLocked`.
        case systemScreenDidLock
    }

    /// What the controller should do when a session event arrives while locked.
    enum SessionReaction: Equatable {
        /// Re-hold keep-awake, re-enable the tap, re-front shields. Also clear
        /// any stuck in-flight auth so the next touch can re-present.
        case reaffirm
        /// Drop Medusa's lock entirely — the human already authenticated at the
        /// system boundary (or the session is no longer ours to hold).
        case release
        /// Surrender the display and input path to macOS's lock screen **without**
        /// clearing Medusa's locked state. Hide shields and stop the event tap so
        /// loginwindow's password field is reachable; stay "locked" underneath so
        /// a later system unlock still runs the release path (never-trap). Do **not**
        /// re-front or re-arm while yielded — that is the password-field trap.
        case yield
        /// No-op (still update any local "system screen locked" flag the
        /// controller tracks when the event is a system lock/unlock).
        case ignore
    }

    /// Maps an `evaluatePolicy` result onto the recovery decision.
    ///
    /// Security boundary: user-driven outcomes keep the lock up (a bystander
    /// mashing Cancel must not pop it); only genuine system-can't-present
    /// failures release it. A cancel MUST re-arm — never leave the cue dead.
    static func authReaction(
        success: Bool,
        error: Error?,
        priorWedgeCount: Int,
        wedgeReleaseThreshold: Int = 2
    ) -> (reaction: AuthReaction, nextWedgeCount: Int) {
        if success { return (.unlock, 0) }

        switch classify(success: false, error: error) {
        case .success:
            return (.unlock, 0)
        case .userCanceledOrFailed:
            return (.rearmAndStayLocked, 0)
        case .cannotPresentNow:
            let next = priorWedgeCount + 1
            if next >= wedgeReleaseThreshold {
                return (.unlockFailOpen, next)
            }
            return (.retryAuthSoon, next)
        case .cannotPresentEver:
            return (.unlockFailOpen, priorWedgeCount)
        }
    }

    /// Maps an LA result onto the historical four-way outcome. Kept as the
    /// single source of truth for both production and the policy harness.
    static func classify(success: Bool, error: Error?) -> AuthOutcome {
        if success { return .success }
        guard let code = (error as? LAError)?.code else { return .userCanceledOrFailed }

        switch code {
        case .userCancel, .userFallback, .authenticationFailed,
             .biometryLockout, .biometryNotAvailable, .biometryNotEnrolled:
            return .userCanceledOrFailed
        case .passcodeNotSet, .notInteractive, .invalidContext:
            return .cannotPresentEver
        default:
            // systemCancel, appCancel, and anything unknown.
            return .cannotPresentNow
        }
    }

    /// Decide how to react to a wake / session / system-lock event.
    ///
    /// The load-bearing rule that used to trap people: after the human unlocks
    /// macOS's own lock screen (power button → system lock → Touch ID), Medusa
    /// must **release**, not reaffirm. Reaffirming re-fronts the shield over a
    /// session the user already paid for with system auth — the only way out
    /// then is force-shutdown.
    ///
    /// `systemScreenLocked` is the controller's latched view of whether macOS's
    /// own lock UI is currently up. Wake events that fire while it is up must
    /// not re-front Medusa on top of the system lock.
    static func sessionReaction(
        event: SessionEvent,
        isLocked: Bool,
        systemScreenLocked: Bool
    ) -> SessionReaction {
        guard isLocked else { return .ignore }

        switch event {
        case .systemScreenDidUnlock:
            // System auth succeeded. Honor it — drop Medusa.
            return .release
        case .systemScreenDidLock:
            // macOS took over the display. Merely "ignoring" reaffirm is not
            // enough: a shield at CGShieldingWindowLevel and a live key-swallowing
            // tap still sit on top of loginwindow and block the password field
            // (force-shutdown was the only way out). Yield — hide + stop tap —
            // while staying notionally locked so unlock still releases.
            return .yield
        case .didWake, .screensDidWake, .sessionDidBecomeActive:
            // Display / machine came back. If the system lock screen is the one
            // currently owning the display, stay quiet — reaffirming would cover
            // loginwindow and strand the user after they authenticate there.
            // Otherwise re-arm tap + assertion + overlays so a long lock that
            // brushed display sleep doesn't look dead.
            if systemScreenLocked { return .ignore }
            return .reaffirm
        }
    }

    // MARK: - System-lock preempt (idle / ⌃⌘Q → Medusa)

    /// What the preempt monitor should do after sampling idle time or a chord.
    enum PreemptAction: Equatable {
        /// Stay idle; keep polling.
        case none
        /// Engage Medusa now (auto-lock path — keep-awake forced by the controller).
        case autoLock
    }

    /// Idle crossed the threshold while the setting is on and Medusa is free.
    static func idlePreempt(
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

    /// ⌃⌘Q (or any configured lock chord) seen while the setting is on and free.
    static func chordPreempt(enabled: Bool, isLocked: Bool) -> PreemptAction {
        guard enabled, !isLocked else { return .none }
        return .autoLock
    }

    /// macOS posted `com.apple.screenIsLocked` while Medusa was still unlocked.
    /// We lost the race — never cover loginwindow; optionally warn once.
    static func shouldWarnRaceLoss(
        enabled: Bool,
        isLocked: Bool,
        alreadyWarned: Bool
    ) -> Bool {
        enabled && !isLocked && !alreadyWarned
    }

    /// Auto-locks from preempt always hold keep-awake; manual locks follow the toggle.
    static func shouldHoldKeepAwake(forceKeepAwake: Bool, keepAwakeSetting: Bool) -> Bool {
        forceKeepAwake || keepAwakeSetting
    }
}
