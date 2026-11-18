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
    /// Starts one system evaluation and returns the call that cancels it. The
    /// reply may arrive on any thread. Injected so the lock lifecycle can be
    /// driven without a finger on the sensor.
    typealias Evaluate = (_ reason: String, _ reply: @escaping (Bool, Error?) -> Void) -> () -> Void

    private(set) var isAuthenticating = false

    private let evaluate: Evaluate
    /// Counts attempts so a reply that outlives `reset()` can't be mistaken
    /// for the answer to a newer dialog.
    private var attempt = 0
    /// Cancels the in-flight evaluation (sleep mid-dialog, system lock
    /// takeover). Without it, a lost reply leaves `isAuthenticating == true`
    /// forever and every later unlock cue is a silent no-op.
    private var cancelInFlight: (() -> Void)?

    init(evaluate: @escaping Evaluate = Authenticator.systemDialog) {
        self.evaluate = evaluate
    }

    static let systemDialog: Evaluate = { reason, reply in
        let context = LAContext()
        context.localizedFallbackTitle = "Enter Password"
        context.localizedCancelTitle = "Cancel"
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason, reply: reply)
        return { context.invalidate() }
    }

    func authenticate(reason: String, completion: @escaping (AuthOutcome) -> Void) {
        guard !isAuthenticating else { return }
        isAuthenticating = true
        attempt += 1
        let current = attempt

        cancelInFlight = evaluate(reason) { [weak self] success, error in
            DispatchQueue.main.async {
                guard let self, self.isAuthenticating, self.attempt == current else { return }
                self.cancelInFlight = nil
                self.isAuthenticating = false
                completion(LockPolicy.classify(success: success, error: error))
            }
        }
    }

    /// Abort any in-flight evaluation and clear the busy flag. Called when the
    /// current dialog can no longer be reached. The cancelled evaluation still
    /// replies eventually, and that reply is dropped above.
    func reset() {
        let cancel = cancelInFlight
        cancelInFlight = nil
        isAuthenticating = false
        cancel?()
    }
}
