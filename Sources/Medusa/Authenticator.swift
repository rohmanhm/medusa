import Foundation
import LocalAuthentication

/// The result of one unlock attempt, classified so the caller can tell three
/// very different situations apart:
///
/// - `.success` — authenticated; unlock.
/// - `.userCanceledOrFailed` — the human backed out or a fingerprint missed.
///   The dialog can be summoned again, so we stay locked and wait for the next
///   touch. Crucially, canceling must NOT release the lock — otherwise anyone
///   could pop it just by mashing Cancel.
/// - `.cannotPresentNow` — the *system* dismissed auth (e.g. `systemCancel`).
///   Might be transient; worth one more try before giving up.
/// - `.cannotPresentEver` — no auth UI can be shown at all (`notInteractive`,
///   `invalidContext`, or no account credential). A shield with no reachable
///   unlock is a trap, so the caller must fail open and release.
enum AuthOutcome {
    case success
    case userCanceledOrFailed
    case cannotPresentNow
    case cannotPresentEver
}

/// Wraps LocalAuthentication for unlocking. Uses `.deviceOwnerAuthentication`
/// so the flow is Touch ID (or Apple Watch) with a free fall-back to the login
/// password — covering Macs without Touch ID and biometric lockout.
///
/// We deliberately do *not* gate on `canEvaluatePolicy`: it reports false in
/// clamshell / external-keyboard setups even when auth would succeed (a
/// long-standing, DTS-confirmed quirk). We just evaluate and react to the
/// result.
final class Authenticator {
    private(set) var isAuthenticating = false
    /// Retained so `reset()` can invalidate an in-flight evaluation (sleep mid-
    /// dialog, system lock takeover). Without this, a lost completion leaves
    /// `isAuthenticating == true` forever and every subsequent unlock cue is a
    /// silent no-op — the cancel-then-stuck trap.
    private var activeContext: LAContext?

    func authenticate(reason: String, completion: @escaping (AuthOutcome) -> Void) {
        guard !isAuthenticating else { return }
        isAuthenticating = true

        let context = LAContext()
        context.localizedFallbackTitle = "Enter Password"
        context.localizedCancelTitle = "Cancel"
        activeContext = context

        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { [weak self] success, error in
            DispatchQueue.main.async {
                guard let self else { return }
                // A reset() may have already cleared this evaluation. Drop the
                // stale completion so it can't fight a newer attempt.
                guard self.activeContext === context else { return }
                self.activeContext = nil
                self.isAuthenticating = false
                completion(LockPolicy.classify(success: success, error: error))
            }
        }
    }

    /// Abort any in-flight evaluation and clear the busy flag. Called when a
    /// session reaffirm or system-lock takeover means the current dialog is no
    /// longer reachable — without this, the next touch is swallowed by
    /// `guard !isAuthenticating`.
    func reset() {
        let context = activeContext
        activeContext = nil
        isAuthenticating = false
        // invalidate() cancels evaluatePolicy and (eventually) fires its reply;
        // we already nil'd activeContext so that reply is ignored above.
        context?.invalidate()
    }
}
