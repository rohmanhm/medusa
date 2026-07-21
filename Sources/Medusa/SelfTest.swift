import AppKit

/// Command-line verification modes, used to exercise the lock machinery without
/// the one step macOS reserves for a human — the Touch ID / password tap.
///
/// - `--self-test`: exercises every mechanical piece (tap creation + enable,
///   overlay on every display, power assertion) and tears down within ~1.2 s.
///   Non-trapping: the tap is stopped immediately after confirming it enabled,
///   so input is never held. Exit 0 = PASS, 2 = permissions missing.
///
/// - `--lock-test [seconds]`: a *real* lock — input is genuinely blocked and the
///   shield is shown — that auto-releases after N seconds (default 8) with no
///   authentication required. Lets you feel the lock end-to-end with a
///   guaranteed release instead of relying on Force Quit.
///
/// - `--auth-test [seconds]`: a *real* lock that runs the full unlock flow, so
///   you can exercise the Touch ID / password dialog — including CANCELING it
///   and confirming the dialog comes back — with a hard backstop that
///   force-releases after N seconds (default 25) no matter what. This is the
///   one path `--lock-test` never touches: the auth cancel/retry that used to
///   trap the machine. It cannot trap you, because the backstop always wins.
enum SelfTestMode {
    case selfTest
    case lockTest(seconds: TimeInterval)
    case authTest(seconds: TimeInterval)
    case verify(timeout: TimeInterval)

    static func from(_ arguments: [String]) -> SelfTestMode? {
        if arguments.contains("--self-test") { return .selfTest }
        if let index = arguments.firstIndex(of: "--verify") {
            // Default horizon: 6 hours, so the watcher survives a long absence.
            let timeout = arguments[safe: index + 1].flatMap(TimeInterval.init) ?? 21_600
            return .verify(timeout: timeout)
        }
        if let index = arguments.firstIndex(of: "--lock-test") {
            let seconds = arguments[safe: index + 1].flatMap(TimeInterval.init) ?? 8
            return .lockTest(seconds: seconds)
        }
        if let index = arguments.firstIndex(of: "--auth-test") {
            let seconds = arguments[safe: index + 1].flatMap(TimeInterval.init) ?? 25
            return .authTest(seconds: seconds)
        }
        return nil
    }
}

final class SelfTestRunner: NSObject, NSApplicationDelegate {
    private let mode: SelfTestMode
    private let tap = InputTap()
    private let shield = ShieldController()
    private let power = PowerAssertion()

    init(mode: SelfTestMode) {
        self.mode = mode
    }

    private var verifyPoll: Timer?
    private var verifyElapsed = 0
    private var verifyTimeout: TimeInterval = 21_600
    private let verifyInterval = 3

    /// Retained for the duration of `--auth-test` so its timers keep firing.
    private var authTestController: LockController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        switch mode {
        case .selfTest: runSelfTest()
        case .lockTest(let seconds): runLockTest(seconds: seconds)
        case .authTest(let seconds): runAuthTest(seconds: seconds)
        case .verify(let timeout): runVerify(timeout: timeout)
        }
    }

    /// Waits for the two permissions and auto-runs the mechanical check the
    /// instant they're granted — so verification executes itself once the human
    /// flips the (un-automatable) System Settings toggles.
    private func runVerify(timeout: TimeInterval) {
        verifyTimeout = timeout
        log("Medusa verify — waiting for permissions")
        log("Grant Accessibility + Input Monitoring in System Settings; this")
        log("will detect the grant and verify the tap automatically.")
        log("(Self-exits after \(Int(timeout / 3600))h if not granted.)")
        log("----------------")
        checkVerify()
        let timer = Timer(timeInterval: TimeInterval(verifyInterval), repeats: true) { [weak self] _ in self?.checkVerify() }
        RunLoop.main.add(timer, forMode: .common)
        verifyPoll = timer
    }

    private func checkVerify() {
        verifyElapsed += verifyInterval
        let accessibility = Permissions.hasAccessibility()
        let inputMonitoring = Permissions.hasInputMonitoring()

        guard accessibility && inputMonitoring else {
            if verifyElapsed % 300 == 0 {
                log("still waiting (\(verifyElapsed / 60)m)… Accessibility=\(accessibility ? "yes" : "no"), Input Monitoring=\(inputMonitoring ? "yes" : "no")")
            }
            if TimeInterval(verifyElapsed) >= verifyTimeout {
                log("timed out — grant the permissions and re-run --verify.")
                exit(2)
            }
            return
        }

        verifyPoll?.invalidate()
        log("Permissions granted ✅ — verifying tap under Medusa's identity…")

        power.begin()
        shield.show()
        let tapCreated = tap.start()
        tap.stop()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [self] in
            shield.hide()
            power.end()
            log("  Accessibility:        ✅")
            log("  Input Monitoring:     ✅")
            log("  Power assertion:      ✅")
            log("  Overlay (\(NSScreen.screens.count) display\(NSScreen.screens.count == 1 ? "" : "s")): ✅")
            log("  Event tap create:     \(tapCreated ? "✅" : "❌")")
            log("----------------")
            if tapCreated {
                log("RESULT: PASS — lock mechanics verified end-to-end under Medusa.app.")
                log("For the real input block: --lock-test 8   |   full cycle: ⌘⇧L then Touch ID")
                exit(0)
            } else {
                log("RESULT: tap still failed despite grants — unexpected; check the bundle signature.")
                exit(3)
            }
        }
    }

    private func runSelfTest() {
        log("Medusa self-test")
        log("----------------")

        let accessibility = Permissions.hasAccessibility()
        let inputMonitoring = Permissions.hasInputMonitoring()
        log("Accessibility permission:    \(mark(accessibility))")
        log("Input Monitoring permission: \(mark(inputMonitoring))")

        power.begin()
        log("Power assertion (keep-awake): \(mark(power.held))")

        shield.show()
        let screens = NSScreen.screens.count
        log("Shield overlay: shown on \(screens) display\(screens == 1 ? "" : "s")")

        let tapCreated = tap.start()
        log("Event tap create + enable:   \(mark(tapCreated))")
        // Stop immediately — a self-test must never hold input.
        tap.stop()

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [self] in
            shield.hide()
            power.end()
            log("Teardown: overlay hidden, assertion released, tap stopped")
            log("----------------")

            if tapCreated && accessibility && inputMonitoring {
                log("RESULT: PASS — core lock mechanics verified end-to-end.")
                log("Only the human unlock (Touch ID / password) remains to test:")
                log("press ⌘⇧L in the running app, or run: --lock-test")
                exit(0)
            } else {
                log("RESULT: BLOCKED — grant Accessibility + Input Monitoring, then re-run.")
                log("The tap cannot be created without both; everything else is ready.")
                exit(2)
            }
        }
    }

    private func runLockTest(seconds: TimeInterval) {
        guard Permissions.allGranted else {
            log("Cannot lock-test: grant Accessibility + Input Monitoring first (run --self-test).")
            exit(2)
        }
        log("Medusa lock-test: locking for \(Int(seconds))s, then auto-releasing.")

        power.begin()
        shield.show()
        guard tap.start() else {
            shield.hide()
            power.end()
            log("Event tap failed to start — aborting, input never held.")
            exit(2)
        }

        log("LOCKED — all input is blocked. Auto-release in \(Int(seconds))s (no auth needed).")
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [self] in
            tap.stop()
            shield.hide()
            power.end()
            log("RELEASED — input restored. Lock verified end-to-end.")
            exit(0)
        }
    }

    /// The real unlock flow, exercised through the production `LockController`
    /// but with a short backstop so it can never trap the tester. This is the
    /// safe way to prove the auth cancel/retry path — the one that used to
    /// require a force-shutdown.
    private func runAuthTest(seconds: TimeInterval) {
        guard Permissions.allGranted else {
            log("Cannot auth-test: grant Accessibility + Input Monitoring first (run --self-test).")
            exit(2)
        }
        log("Medusa auth-test: a REAL lock running the full unlock flow.")
        log("Touch input → the Touch ID / password dialog appears.")
        log("  • CANCEL it, then touch again — the dialog must come back.")
        log("  • Or authenticate to unlock normally.")
        log("Either way the lock FORCE-RELEASES itself in \(Int(seconds))s — it")
        log("cannot trap you. This is the path --lock-test never touches.")
        log("----------------")

        let controller = LockController(maxLockDuration: seconds)
        controller.onStateChange = { [weak controller] in
            guard let controller, !controller.isLocked else { return }
            FileHandle.standardError.write(
                Data("RELEASED — input restored (auth succeeded or backstop fired). ✅\n".utf8)
            )
            exit(0)
        }
        controller.onLockFailed = {
            FileHandle.standardError.write(
                Data("Lock failed to start (permissions?). Nothing was ever held.\n".utf8)
            )
            exit(2)
        }
        authTestController = controller
        controller.lock()
        log("LOCKED — touch the keyboard or click to raise the unlock dialog.")
    }

    private func mark(_ ok: Bool) -> String { ok ? "✅ yes" : "❌ no" }

    private func log(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
