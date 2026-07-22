import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let lock = LockController()
    private let menuBar = MenuBarController()
    private let hotKey = HotKey()
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
}
