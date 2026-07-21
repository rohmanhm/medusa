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
}
