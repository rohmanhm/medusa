import AppKit

/// Orchestrates the lock lifecycle: shield overlays, the input tap, the
/// keep-awake assertion, and the unlock authentication flow.
///
/// Two invariants guide everything here:
/// - **Fail open** — if we can't actually block input, never leave a shield up
///   that only *looks* like it's blocking.
/// - **Never trap** — no single misbehaving unlock path may hold the machine
///   hostage. The re-activation fix, the wedge detector, the system-unlock
///   release, and the backstop timer are layered so that "force-shutdown" is
///   never the only way out — without handing a bystander a cheap unlock.
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

    /// Latched from `com.apple.screenIsLocked` / `…Unlocked`. While true, wake
    /// reaffirm is suppressed so we never cover loginwindow — and a subsequent
    /// system unlock releases Medusa entirely (the power-button trap fix).
    private var systemScreenLocked = false

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
        systemScreenLocked = false
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
            let (reaction, nextWedge) = Self.reaction(for: outcome, priorWedge: self.wedgeCount)
            self.wedgeCount = nextWedge
            switch reaction {
            case .unlock, .unlockFailOpen:
                self.unlock()

            case .rearmAndStayLocked:
                // Normal: the user backed out or a fingerprint missed. Stay
                // locked and let the next touch summon the dialog again.
                self.shield.setAuthMode(false)
                self.tap.rearm()

            case .retryAuthSoon:
                // The system took the dialog away. Try once more ourselves; if
                // it happens again, the machine can't show auth — fail open
                // (handled via nextWedge on the subsequent outcome).
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    self?.beginAuth()
                }
            }
        }
    }

    /// Bridge `AuthOutcome` → `LockPolicy.AuthReaction` so the controller and the
    /// pure policy harness share one decision table.
    private static func reaction(
        for outcome: AuthOutcome,
        priorWedge: Int
    ) -> (LockPolicy.AuthReaction, Int) {
        switch outcome {
        case .success:
            return (.unlock, 0)
        case .userCanceledOrFailed:
            return (.rearmAndStayLocked, 0)
        case .cannotPresentNow:
            let next = priorWedge + 1
            if next >= wedgeReleaseThreshold {
                return (.unlockFailOpen, next)
            }
            return (.retryAuthSoon, next)
        case .cannotPresentEver:
            return (.unlockFailOpen, priorWedge)
        }
    }

    private func unlock() {
        stopBackstop()
        stopSessionObservers()
        auth.reset()
        tap.stop()
        shield.hide()
        power.end()
        wedgeCount = 0
        keepAwakeWarned = false
        systemScreenLocked = false
        isLocked = false
        onStateChange?()
    }

    // MARK: - Sleep / wake / session re-arm / system lock

    /// Sleep, wake, fast-user-switch, and the system lock screen can disable the
    /// event tap, drop the power assertion, leave overlays behind loginwindow,
    /// or — the trap — leave Medusa locked after the human already authenticated
    /// at the system boundary. Observe all of it and route through `LockPolicy`.
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

        // Power-button trap fix: macOS posts these when its own lock screen
        // appears / is dismissed. Without them, a system unlock leaves
        // isLocked=true and the next didWake reaffirms the shield over a
        // session the user already paid for — force-shutdown was the only exit.
        let distributed = DistributedNotificationCenter.default()
        distributed.addObserver(
            self,
            selector: #selector(systemScreenDidLock),
            name: Notification.Name("com.apple.screenIsLocked"),
            object: nil
        )
        distributed.addObserver(
            self,
            selector: #selector(systemScreenDidUnlock),
            name: Notification.Name("com.apple.screenIsUnlocked"),
            object: nil
        )
    }

    private func stopSessionObservers() {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        DistributedNotificationCenter.default().removeObserver(self)
    }

    @objc private func systemDidWake() { handleSessionEvent(.didWake) }
    @objc private func sessionDidBecomeActive() { handleSessionEvent(.sessionDidBecomeActive) }
    @objc private func screensDidWake() { handleSessionEvent(.screensDidWake) }
    @objc private func systemScreenDidLock() {
        // Distributed notifications can arrive off the main thread; hop first.
        DispatchQueue.main.async { [weak self] in self?.handleSessionEvent(.systemScreenDidLock) }
    }
    @objc private func systemScreenDidUnlock() {
        DispatchQueue.main.async { [weak self] in self?.handleSessionEvent(.systemScreenDidUnlock) }
    }

    private func handleSessionEvent(_ event: LockPolicy.SessionEvent) {
        // Latch the system-lock flag before consulting policy so a wake that
        // races with screenIsLocked sees the right state.
        switch event {
        case .systemScreenDidLock:
            systemScreenLocked = true
            // The system dialog replaced ours; any in-flight LA evaluation is
            // unreachable. Clear it so a later Medusa cue isn't a silent no-op.
            auth.reset()
            shield.setAuthMode(false)
            tap.rearm()
        case .systemScreenDidUnlock:
            systemScreenLocked = false
        case .didWake, .screensDidWake, .sessionDidBecomeActive:
            break
        }

        let reaction = LockPolicy.sessionReaction(
            event: event,
            isLocked: isLocked,
            systemScreenLocked: systemScreenLocked
        )
        switch reaction {
        case .release:
            unlock()
        case .reaffirm:
            reaffirmLock()
        case .ignore:
            break
        }
    }

    /// Re-hold the keep-awake assertion, re-enable the tap, clear any stuck auth
    /// flag, and re-front the shields. Safe to call spuriously — every step is
    /// idempotent while locked.
    private func reaffirmLock() {
        guard isLocked else { return }
        // Sleep mid-dialog can leave isAuthenticating latched if the LA
        // completion was lost or delayed. Reset so the next touch re-presents
        // instead of dying in `guard !isAuthenticating`.
        if auth.isAuthenticating {
            auth.reset()
            shield.setAuthMode(false)
            tap.rearm()
        }
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
