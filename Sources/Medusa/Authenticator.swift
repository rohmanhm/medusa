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

    func authenticate(reason: String, completion: @escaping (AuthOutcome) -> Void) {
        guard !isAuthenticating else { return }
        isAuthenticating = true

        let context = LAContext()
        context.localizedFallbackTitle = "Enter Password"
        context.localizedCancelTitle = "Cancel"

        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { [weak self] success, error in
            DispatchQueue.main.async {
                self?.isAuthenticating = false
                completion(Self.classify(success: success, error: error))
            }
        }
    }

    /// Maps an `evaluatePolicy` result onto the three-way recovery decision.
    /// The mapping is the security boundary of the whole failsafe: user-driven
    /// outcomes keep the lock up; only genuine system-can't-present failures
    /// release it.
    private static func classify(success: Bool, error: Error?) -> AuthOutcome {
        if success { return .success }
        guard let code = (error as? LAError)?.code else { return .userCanceledOrFailed }

        switch code {
        case .userCancel, .userFallback, .authenticationFailed,
             .biometryLockout, .biometryNotAvailable, .biometryNotEnrolled:
            // Human backed out, or biometry is unusable but the password path
            // still exists. Recoverable — never auto-release on these.
            return .userCanceledOrFailed

        case .passcodeNotSet, .notInteractive, .invalidContext:
            // No credential to check, or we simply cannot present UI from here.
            // Releasing is the only non-trapping choice.
            return .cannotPresentEver

        default:
            // systemCancel, appCancel, and anything unknown: the system took the
            // dialog away. Retry once; the caller releases if it recurs.
            return .cannotPresentNow
        }
    }
}
