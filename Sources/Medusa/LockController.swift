import AppKit

/// Orchestrates the lock lifecycle: shield overlays, the input tap, the
/// keep-awake assertion, and the unlock authentication flow.
///
/// Two invariants guide everything here:
/// - **Fail open** — if we can't actually block input, never leave a shield up
///   that only *looks* like it's blocking.
/// - **Never trap** — no single misbehaving unlock path may hold the machine
///   hostage. The re-activation fix, the wedge detector, and the backstop timer
///   are layered so that "force-shutdown" is never the only way out — without
///   handing a bystander a cheap unlock.
final class LockController {
    private let tap = InputTap()
    private let shield = ShieldController()
    private let power = PowerAssertion()
    private let auth = Authenticator()

    /// Absolute backstop. However badly the unlock path misbehaves, the lock
    /// releases itself after this long. Under normal use Touch ID lifts the lock
    /// in seconds and this never fires — it's the dead-man's-switch for the case
    /// where every other recovery somehow fails. Waiting it out is no practical
    /// bypass, so it costs no real security. Nil means "read the user's setting
    /// at lock time"; the test harness passes an explicit short horizon.
    private let maxLockDurationOverride: TimeInterval?
    private var backstop: Timer?

    /// Consecutive "the system couldn't show the auth UI" outcomes. Two in a row
    /// means the dialog is genuinely wedged, so we fail open. User cancels reset
    /// it to zero and never count — otherwise mashing Cancel would pop the lock.
    private var wedgeCount = 0
    private static let wedgeReleaseThreshold = 2

    /// Keep-awake failure is reported at most once per lock so sleep/wake re-arm
    /// doesn't spam the same alert every time the display cycles.
    private var keepAwakeWarned = false

    private(set) var isLocked = false

    /// Notifies observers (the menu bar) that lock state changed.
    var onStateChange: (() -> Void)?

    /// Called when a lock is requested but the tap can't be installed — the
    /// caller surfaces this (usually a permission gap).
    var onLockFailed: (() -> Void)?

    /// Keep-awake was requested but the kernel refused the power assertion. The
    /// lock still holds (input is blocked, shield is up) — only the "display
    /// stays lit" promise is broken. Fired at most once per lock session.
    var onKeepAwakeFailed: (() -> Void)?

    /// - Parameter maxLockDuration: an explicit backstop horizon. The real app
    ///   omits it (each lock reads the configurable setting, default 4 hours);
    ///   the `--auth-test` harness passes a few seconds so the lock can never
    ///   trap the tester.
    init(maxLockDuration: TimeInterval? = nil) {
        self.maxLockDurationOverride = maxLockDuration
    }

    func toggle() {
        isLocked ? requestUnlock() : lock()
    }

    func lock() {
        guard !isLocked, Permissions.allGranted else {
            if !Permissions.allGranted { onLockFailed?() }
            return
        }

        // Arm the shield + tap first so a slow keep-awake alert can never leave
        // the user staring at a black screen that isn't actually blocking input.
        shield.show()
        tap.onInteraction = { [weak self] in self?.beginAuth() }
        guard tap.start() else {
            // Fail open: never trap the user behind a non-blocking shield.
            shield.hide()
            power.end()
            onLockFailed?()
            return
        }

        wedgeCount = 0
        keepAwakeWarned = false
        if AppSettings.keepAwake {
            reportKeepAwakeFailureIfNeeded(held: power.begin())
        }

        isLocked = true
        startBackstop()
        startSessionObservers()
        onStateChange?()
    }

    /// Manual unlock request (e.g. from the menu) — routes through the same auth
    /// flow as touching the keyboard/mouse.
    func requestUnlock() {
        guard isLocked else { return }
        beginAuth()
    }

    /// Drop the shield to auth level for a short AppKit interaction (alerts),
    /// then restore full shielding. Auth-in-progress is left alone.
    func withShieldLowered(_ work: () -> Void) {
        guard isLocked else {
            work()
            return
        }
        let wasAuthenticating = auth.isAuthenticating
        if !wasAuthenticating { shield.setAuthMode(true) }
        work()
        if isLocked, !auth.isAuthenticating {
            shield.setAuthMode(false)
        }
    }

    private func beginAuth() {
        guard isLocked, !auth.isAuthenticating else { return }

        shield.setAuthMode(true)
        // Re-front on EVERY attempt, not just the first lock. An accessory
        // (menu-bar) app that isn't frontmost cannot reliably re-present
        // coreauthd's dialog after a cancel — the exact wedge that trapped the
        // machine. Activating first makes the retry dialog actually appear.
        NSApp.activate(ignoringOtherApps: true)

        auth.authenticate(reason: "unlock your Mac") { [weak self] outcome in
            guard let self, self.isLocked else { return }
            switch outcome {
            case .success:
                self.unlock()

            case .userCanceledOrFailed:
                // Normal: the user backed out or a fingerprint missed. Stay
                // locked and let the next touch summon the dialog again.
                self.wedgeCount = 0
                self.shield.setAuthMode(false)
                self.tap.rearm()

            case .cannotPresentNow:
                // The system took the dialog away. Try once more ourselves; if
                // it happens again, the machine can't show auth — fail open.
                self.wedgeCount += 1
                if self.wedgeCount >= Self.wedgeReleaseThreshold {
                    self.unlock()
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                        self?.beginAuth()
                    }
                }

            case .cannotPresentEver:
                // No credential, or UI can't be shown at all — never trap.
                self.unlock()
            }
        }
    }

    private func unlock() {
        stopBackstop()
        stopSessionObservers()
        tap.stop()
        shield.hide()
        power.end()
        wedgeCount = 0
        keepAwakeWarned = false
        isLocked = false
        onStateChange?()
    }

    // MARK: - Sleep / wake / session re-arm

    /// Sleep, wake, and fast-user-switch can disable the event tap, drop the
    /// power assertion, or leave overlays behind the system lock UI. Re-arm so
    /// a long lock that brushes display sleep doesn't look like "Medusa died
    /// and macOS took over."
    private func startSessionObservers() {
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(
            self,
            selector: #selector(systemDidWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        workspace.addObserver(
            self,
            selector: #selector(sessionDidBecomeActive),
            name: NSWorkspace.sessionDidBecomeActiveNotification,
            object: nil
        )
        workspace.addObserver(
            self,
            selector: #selector(screensDidWake),
            name: NSWorkspace.screensDidWakeNotification,
            object: nil
        )
    }

    private func stopSessionObservers() {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    @objc private func systemDidWake() { reaffirmLock() }
    @objc private func sessionDidBecomeActive() { reaffirmLock() }
    @objc private func screensDidWake() { reaffirmLock() }

    /// Re-hold the keep-awake assertion, re-enable the tap, and re-front the
    /// shields. Safe to call spuriously — every step is idempotent while locked.
    private func reaffirmLock() {
        guard isLocked else { return }
        if AppSettings.keepAwake {
            reportKeepAwakeFailureIfNeeded(held: power.reaffirm())
        }
        tap.ensureEnabled()
        shield.reaffirm()
    }

    private func reportKeepAwakeFailureIfNeeded(held: Bool) {
        guard !held, !keepAwakeWarned else { return }
        keepAwakeWarned = true
        // Async so the lock path finishes arming before any modal UI runs.
        DispatchQueue.main.async { [weak self] in
            self?.onKeepAwakeFailed?()
        }
    }

    // MARK: - Backstop

    private func startBackstop() {
        stopBackstop()
        let duration = maxLockDurationOverride ?? AppSettings.backstopDuration
        // "Never" (0) skips the timer; the wedge detector and fail-open paths
        // still guarantee the lock can't trap.
        guard duration > 0 else { return }
        let timer = Timer(timeInterval: duration, repeats: false) { [weak self] _ in
            self?.unlock()
        }
        RunLoop.main.add(timer, forMode: .common)
        backstop = timer
    }

    private func stopBackstop() {
        backstop?.invalidate()
        backstop = nil
    }
}
