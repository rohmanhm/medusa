import AppKit
import Sparkle

/// The `NSStatusItem` menu — Medusa's only persistent UI surface.
///
/// One status item, no second icon. The button handles clicks directly (left
/// opens the menu, right/⌃-click is Quick start) instead of assigning
/// `statusItem.menu`, so the Quick-start gesture from the spec is real.
final class MenuBarController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let lockItem = NSMenuItem(title: "Lock Now", action: nil, keyEquivalent: "")
    private let keepAwakeItem = NSMenuItem(title: "Keep Awake", action: nil, keyEquivalent: "")
    private let keepAwakeMenu = NSMenu()
    private let aboutItem = NSMenuItem(title: "About Medusa", action: nil, keyEquivalent: "")

    var onLock: (() -> Void)?
    var onSettings: (() -> Void)?

    /// Keep Awake wiring. The controller reads live state for rebuilds; all
    /// behaviors run through the closures so the menu stays dumb.
    var keepAwake: KeepAwakeController?
    var isLocked: (() -> Bool)?
    var onQuickStart: (() -> Void)?
    var onStartSession: ((KeepAwakeEndCondition, AwakeLevel) -> Void)?
    var onExtendSession: ((Int) -> Void)?
    var onStopSession: (() -> Void)?

    private var lastCountdown: String?

    override init() {
        super.init()
        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "eye.trianglebadge.exclamationmark",
                accessibilityDescription: "Medusa"
            )
            button.image?.isTemplate = true
            button.target = self
            button.action = #selector(statusClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        lockItem.target = self
        lockItem.action = #selector(lockTapped)
        menu.addItem(lockItem)

        keepAwakeItem.submenu = keepAwakeMenu
        menu.addItem(keepAwakeItem)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(settingsTapped), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        aboutItem.target = self
        aboutItem.action = #selector(aboutTapped)
        menu.addItem(aboutItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit Medusa", action: #selector(quitTapped), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        menu.delegate = self
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

    /// Reflects the current lock state in the menu label and icon.
    func setLocked(_ locked: Bool) {
        lockItem.title = locked ? "Unlock" : "Lock Now"
        refreshState()
    }

    /// Session/hold change path — refresh icon, header, and countdown.
    func refreshState() {
        guard let button = statusItem.button else { return }
        let locked = isLocked?() ?? false
        let awake = (keepAwake?.effectiveLevel) != nil
        let symbol: String
        if locked {
            symbol = "lock.fill"
        } else if awake {
            symbol = "cup.and.saucer.fill"
        } else {
            symbol = "eye.trianglebadge.exclamationmark"
        }
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Medusa")
        button.image?.isTemplate = true
        refreshCountdown()
    }

    /// Lightweight per-tick path — only writes when the text changed.
    func refreshCountdown() {
        guard AppSettings.keepAwakeShowCountdown,
              let text = keepAwake?.countdownText(),
              !(keepAwake.map { $0.hasSession } ?? true)
        else {
            // Countdown off, or indefinite / no Session: no bar text.
            if lastCountdown != nil {
                statusItem.button?.title = ""
                lastCountdown = nil
            }
            return
        }
        if text != lastCountdown {
            statusItem.button?.title = text
            if let button = statusItem.button {
                button.imagePosition = .imageLeading
            }
            lastCountdown = text
        }
    }

    /// Adds "Check for Updates…" below About. Targeting the Sparkle controller
    /// directly gives the item enabled-state validation for free; only called
    /// in builds where the updater actually runs.
    func attachUpdater(_ controller: SPUStandardUpdaterController) {
        let item = NSMenuItem(
            title: "Check for Updates…",
            action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
            keyEquivalent: ""
        )
        item.target = controller
        menu.insertItem(item, at: menu.index(of: aboutItem) + 1)
    }

    // MARK: Clicks

    @objc private func statusClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else {
            popupMenu()
            return
        }
        // Right-click or ⌃-click anywhere on the button = Quick start: toggle
        // a Session with the Default duration without opening the menu.
        if event.type == .rightMouseUp
            || (event.type == .leftMouseUp && event.modifierFlags.contains(.control))
            || event.buttonNumber == 1
        {
            onQuickStart?()
            return
        }
        popupMenu()
    }

    private func popupMenu() {
        guard let button = statusItem.button else { return }
        statusItem.menu = nil
        menu.popUp(
            positioning: nil,
            at: NSPoint(x: 0, y: button.bounds.maxY + 4),
            in: button
        )
    }

    // MARK: Menu content

    func menuWillOpen(_ menu: NSMenu) {
        if menu === self.menu {
            rebuildKeepAwakeRoot()
        }
        refreshShortcut()
    }

    private func rebuildKeepAwakeRoot() {
        keepAwakeItem.isHidden = keepAwake == nil
        rebuildKeepAwakeMenu()
    }

    private func rebuildKeepAwakeMenu() {
        keepAwakeMenu.removeAllItems()
        guard let engine = keepAwake else { return }
        let locked = isLocked?() ?? false

        if let header = engine.headerText() {
            let headerItem = NSMenuItem(title: header, action: nil, keyEquivalent: "")
            headerItem.isEnabled = false
            keepAwakeMenu.addItem(headerItem)

            let extendMenu = NSMenu()
            for minutes in [15, 30, 60] {
                let item = NSMenuItem(
                    title: minutes >= 60 ? "1 hour" : "\(minutes) min",
                    action: #selector(extendTapped(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = minutes
                extendMenu.addItem(item)
            }
            let extendItem = NSMenuItem(title: "Extend", action: nil, keyEquivalent: "")
            extendItem.submenu = extendMenu
            keepAwakeMenu.addItem(extendItem)

            let stopItem = NSMenuItem(title: "Stop Keep Awake", action: #selector(stopTapped), keyEquivalent: "")
            stopItem.target = self
            keepAwakeMenu.addItem(stopItem)
            keepAwakeMenu.addItem(.separator())
        }

        if !locked {
            let indefiniteItem = NSMenuItem(
                title: "Indefinitely", action: #selector(startIndefiniteTapped), keyEquivalent: ""
            )
            indefiniteItem.target = self
            indefiniteItem.state = engine.hasSession && engine.session?.deadline == nil ? .on : .off
            keepAwakeMenu.addItem(indefiniteItem)

            keepAwakeMenu.addItem(.separator())

            for minutes in AppSettings.keepAwakePresetMinutes {
                let item = NSMenuItem(
                    title: Self.presetLabel(minutes: minutes),
                    action: #selector(presetTapped(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = minutes
                keepAwakeMenu.addItem(item)
            }

            keepAwakeMenu.addItem(.separator())

            let untilItem = NSMenuItem(title: "Until…", action: #selector(untilTapped), keyEquivalent: "")
            untilItem.target = self
            keepAwakeMenu.addItem(untilItem)
            let customItem = NSMenuItem(title: "Custom…", action: #selector(customTapped), keyEquivalent: "")
            customItem.target = self
            keepAwakeMenu.addItem(customItem)

            keepAwakeMenu.addItem(.separator())

            let levelItem = NSMenuItem(
                title: "Allow display to sleep",
                action: #selector(levelToggleTapped),
                keyEquivalent: ""
            )
            levelItem.target = self
            levelItem.state = AppSettings.keepAwakeDefaultLevel == .system ? .on : .off
            keepAwakeMenu.addItem(levelItem)
        } else if engine.headerText() == nil {
            let item = NSMenuItem(title: "Unavailable while locked", action: nil, keyEquivalent: "")
            item.isEnabled = false
            keepAwakeMenu.addItem(item)
        }
    }

    private static func presetLabel(minutes: Int) -> String {
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60
        let rest = minutes % 60
        if rest == 0 { return hours == 1 ? "1 hour" : "\(hours) hours" }
        return "\(hours)h \(rest)m"
    }

    private func defaultLevel() -> AwakeLevel { AppSettings.keepAwakeDefaultLevel }

    @objc private func startIndefiniteTapped() {
        onStartSession?(.indefinitely, defaultLevel())
    }

    @objc private func presetTapped(_ sender: NSMenuItem) {
        guard let minutes = sender.representedObject as? Int else { return }
        onStartSession?(.duration(TimeInterval(minutes * 60)), defaultLevel())
    }

    @objc private func extendTapped(_ sender: NSMenuItem) {
        guard let minutes = sender.representedObject as? Int else { return }
        onExtendSession?(minutes)
    }

    @objc private func stopTapped() { onStopSession?() }
    @objc private func untilTapped() { onUntilPicked?() }
    @objc private func customTapped() { onCustomPicked?() }

    var onUntilPicked: (() -> Void)?
    var onCustomPicked: (() -> Void)?

    @objc private func levelToggleTapped(_ sender: NSMenuItem) {
        let next: AwakeLevel = AppSettings.keepAwakeDefaultLevel == .system ? .display : .system
        UserDefaults.standard.set(next.rawValue, forKey: AppSettings.Keys.keepAwakeDefaultLevel)
    }

    private func refreshShortcut() {
        lockItem.keyEquivalent = AppSettings.hotKeyKeyChar
        lockItem.keyEquivalentModifierMask = AppSettings.hotKeyModifiers
    }

    @objc private func defaultsChanged() {
        DispatchQueue.main.async { [weak self] in
            self?.refreshShortcut()
            self?.refreshState()
        }
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
