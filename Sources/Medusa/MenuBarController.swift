import AppKit

/// The `NSStatusItem` menu — Medusa's only persistent UI surface.
final class MenuBarController {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let lockItem = NSMenuItem(title: "Lock Now", action: nil, keyEquivalent: "")

    var onLock: (() -> Void)?
    var onSettings: (() -> Void)?

    init() {
        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "eye.trianglebadge.exclamationmark",
                accessibilityDescription: "Medusa"
            )
            button.image?.isTemplate = true
        }

        lockItem.target = self
        lockItem.action = #selector(lockTapped)
        menu.addItem(lockItem)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(settingsTapped), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let aboutItem = NSMenuItem(title: "About Medusa", action: #selector(aboutTapped), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit Medusa", action: #selector(quitTapped), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
        setLocked(false)
        refreshShortcut()

        // Keep the menu's shortcut hint in sync when it's changed in Settings.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(defaultsChanged),
            name: UserDefaults.didChangeNotification,
            object: nil
        )
    }

    /// Reflects the current lock state in the menu label.
    func setLocked(_ locked: Bool) {
        lockItem.title = locked ? "Unlock" : "Lock Now"
    }

    private func refreshShortcut() {
        lockItem.keyEquivalent = AppSettings.hotKeyKeyChar
        lockItem.keyEquivalentModifierMask = AppSettings.hotKeyModifiers
    }

    @objc private func defaultsChanged() {
        DispatchQueue.main.async { [weak self] in self?.refreshShortcut() }
    }

    @objc private func lockTapped() { onLock?() }
    @objc private func settingsTapped() { onSettings?() }
    @objc private func quitTapped() { NSApp.terminate(nil) }

    @objc private func aboutTapped() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Medusa",
            .init(rawValue: "Copyright"): "Open-source input lock for macOS."
        ])
    }
}
