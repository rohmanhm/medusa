import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let lock = LockController()
    private let menuBar = MenuBarController()
    private let hotKey = HotKey()
    private var settings: SettingsWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppSettings.registerDefaults()

        lock.onStateChange = { [weak self] in
            self?.menuBar.setLocked(self?.lock.isLocked ?? false)
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
            settings = SettingsWindowController()
        }
        settings?.show(tab: tab)
    }
}
