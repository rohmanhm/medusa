import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let lock = LockController()
    private let menuBar = MenuBarController()
    private let hotKey = HotKey()
    private let preempt = SystemLockPreemptMonitor()
    private var settings: SettingsWindowController?
    private var updater: UpdaterController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppSettings.registerDefaults()

        let updater = UpdaterController(isLocked: { [weak lock] in lock?.isLocked ?? false })
        self.updater = updater
        if UpdaterController.updatesSupported {
            menuBar.attachUpdater(updater.menuTarget)
        }

        lock.onStateChange = { [weak self] in
            guard let self else { return }
            self.menuBar.setLocked(self.lock.isLocked)
            self.preempt.medusaLockStateDidChange()
            if !self.lock.isLocked {
                self.updater?.lockDidRelease()
            }
        }
        lock.onLockFailed = { [weak self] in
            self?.showSettings(tab: .permissions)
        }
        lock.onKeepAwakeFailed = { [weak self] in
            self?.alertKeepAwakeFailed()
        }

        menuBar.onLock = { [weak self] in self?.performLockToggle() }
        menuBar.onSettings = { [weak self] in self?.showSettings() }

        hotKey.onTrigger = { [weak self] in self?.performLockToggle() }
        hotKey.start()

        preempt.isMedusaLocked = { [weak lock] in lock?.isLocked ?? false }
        preempt.onAutoLock = { [weak self] in
            self?.performAutoLock()
        }
        preempt.onRaceLossWarning = { [weak self] in
            self?.alertPreemptRaceLoss()
        }
        preempt.onTapFailed = { [weak self] in
            // Chord intercept needs the same Accessibility grant as the lock tap.
            // Idle preempt still works without it; only surface Permissions when
            // the user has the setting on (reconcile only installs while enabled).
            self?.showSettings(tab: .permissions)
        }
        preempt.start()

        if CommandLine.arguments.contains("--settings") {
            // Debug/preview entry: open Settings immediately.
            showSettings()
        }

        // First run (or revoked permissions): walk the user through setup.
        guard Permissions.allGranted else {
            showSettings(tab: .permissions)
            return
        }

        if AppSettings.lockOnLaunch {
            lock.lock()
        }
    }

    private func performLockToggle() {
        guard Permissions.allGranted else {
            showSettings(tab: .permissions)
            return
        }
        lock.toggle()
    }

    /// Idle / ⌃⌘Q path — always forces keep-awake for this lock session.
    private func performAutoLock() {
        guard Permissions.allGranted else {
            showSettings(tab: .permissions)
            return
        }
        guard !lock.isLocked else { return }
        lock.lock(forceKeepAwake: true)
    }

    private func showSettings(tab: SettingsWindowController.Tab? = nil) {
        if settings == nil {
            settings = SettingsWindowController(updater: updater)
        }
        settings?.show(tab: tab)
    }

    /// Keep-awake was requested but the kernel refused the assertion. The lock
    /// still holds — only the lit-display promise is broken. Tell the user once
    /// so a short system display-sleep timer doesn't silently hand the session
    /// to macOS's own lock screen later.
    private func alertKeepAwakeFailed() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Couldn't keep the display awake"
        alert.informativeText =
            "Medusa is locked and input is blocked, but the system refused the "
            + "keep-awake assertion. The display may sleep on its normal schedule "
            + "and macOS may show its own lock screen. Check Energy settings, or "
            + "turn off “Keep Mac awake while locked” if you don't need a lit display."
        alert.addButton(withTitle: "OK")
        // Shield sits at CGShieldingWindowLevel; drop it to the auth level so the
        // alert is actually visible and clickable, then restore.
        lock.withShieldLowered {
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    /// System lock appeared while Medusa was still unlocked — we lost the race.
    /// One-shot; the monitor latches the flag before calling.
    private func alertPreemptRaceLoss() {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "macOS locked before Medusa"
        alert.informativeText =
            "“Engage Medusa when idle” is on, but the system lock screen appeared "
            + "first. Medusa never covers that screen.\n\n"
            + "Set Medusa’s idle time shorter than your display sleep, and keep "
            + "Accessibility granted so ⌃⌘Q can be intercepted when the system allows it. "
            + "This notice won’t show again until you turn the setting off and back on."
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
