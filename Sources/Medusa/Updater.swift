import AppKit
import Security
import Sparkle

/// Owns Sparkle's updater and gates every update path on Medusa's state.
///
/// Two invariants, mirroring the lock's own design:
/// - **Inert while locked** — an update must never tear down the shield: checks
///   are vetoed, scheduled alerts deferred, install-on-quit stalled, and the
///   relaunch refused while a lock is engaged. Anything deferred re-presents
///   when the lock releases.
/// - **Silent in dev builds** — Sparkle itself would happily install a
///   Developer ID release over an ad-hoc build (its EdDSA check passes), but
///   the TCC grants would churn because the ad-hoc designated requirement is
///   pinned to one binary. So the updater only starts in Developer ID-signed
///   builds; `MEDUSA_UPDATER_DEV=1` overrides for local end-to-end testing,
///   and only then is a `MEDUSA_FEED_URL` override honored.
final class UpdaterController: NSObject {
    private let isLocked: () -> Bool
    private var sparkle: SPUStandardUpdaterController!

    /// A scheduled update wanted to show while locked; re-present on unlock.
    private var deferredWhileLocked = false
    /// Held install-on-quit continuation; dropped on unlock (the install still
    /// happens when the app quits — Sparkle guarantees that itself).
    private var heldInstallHandler: (() -> Void)?

    /// True in builds users could actually update in place.
    static let updatesSupported = devOverride || isReleaseSigned

    private static let devOverride =
        ProcessInfo.processInfo.environment["MEDUSA_UPDATER_DEV"] == "1"

    /// Whether the running bundle is Developer ID-signed (the leaf OID Apple
    /// assigns to Developer ID Application certificates).
    private static var isReleaseSigned: Bool {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return false }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
              let staticCode else { return false }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(
            "anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13]" as CFString,
            [], &requirement) == errSecSuccess, let requirement else { return false }
        return SecStaticCodeCheckValidity(staticCode, [], requirement) == errSecSuccess
    }

    init(isLocked: @escaping () -> Bool) {
        self.isLocked = isLocked
        super.init()
        sparkle = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: self,
            userDriverDelegate: self
        )
        if Self.updatesSupported {
            sparkle.startUpdater()
        }
    }

    /// Target for the "Check for Updates…" menu item — pointing the item at
    /// the Sparkle controller gets its enabled-state validation for free.
    var menuTarget: SPUStandardUpdaterController { sparkle }

    /// The underlying updater, for the Settings bindings.
    var updater: SPUUpdater { sparkle.updater }

    /// Called when the lock releases: surface whatever was deferred under it.
    func lockDidRelease() {
        heldInstallHandler = nil
        if deferredWhileLocked {
            deferredWhileLocked = false
            updater.checkForUpdates()
        }
    }
}

// MARK: - SPUUpdaterDelegate (the lock gates)

extension UpdaterController: SPUUpdaterDelegate {
    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        if isLocked() {
            throw NSError(domain: "Medusa.Updater", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Updates pause while the lock is engaged."
            ])
        }
    }

    func feedURLString(for updater: SPUUpdater) -> String? {
        guard Self.devOverride,
              let feed = ProcessInfo.processInfo.environment["MEDUSA_FEED_URL"],
              !feed.isEmpty else { return nil }
        return feed
    }

    func updaterShouldRelaunchApplication(_ updater: SPUUpdater) -> Bool {
        !isLocked()
    }

    func updater(
        _ updater: SPUUpdater,
        willInstallUpdateOnQuit item: SUAppcastItem,
        immediateInstallationBlock immediateInstallHandler: @escaping () -> Void
    ) -> Bool {
        if isLocked() {
            heldInstallHandler = immediateInstallHandler
            return true
        }
        // Test hook: the e2e harness can't click "Install and Relaunch", so a
        // silently downloaded update installs immediately under the override.
        if Self.devOverride {
            immediateInstallHandler()
            return true
        }
        return false
    }
}

// MARK: - SPUStandardUserDriverDelegate (gentle reminders)

extension UpdaterController: SPUStandardUserDriverDelegate {
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        if isLocked() {
            deferredWhileLocked = true
            return false
        }
        return true
    }
}
