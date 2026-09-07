import AppKit
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private let lock = LockController()
    private let keepAwake = KeepAwakeController()
    private let menuBar = MenuBarController()
    private let hotKey = HotKey()
    private let keepAwakeHotKey = HotKey(
        keyCode: { AppSettings.keepAwakeHotKeyKeyCode },
        modifiers: { AppSettings.keepAwakeHotKeyModifiers }
    )
    private let preempt = SystemLockPreemptMonitor()
    private var settings: SettingsWindowController?
    private var updater: UpdaterController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppSettings.registerDefaults()
        KeepAwakeNotifier.registerCategories(delegate: self)

        lock.keepAwakeEngine = keepAwake
        keepAwake.isLocked = { [weak lock] in lock?.isLocked ?? false }

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
        keepAwake.onStateChange = { [weak self] in
            self?.menuBar.refreshState()
            // Sessions pause/resume idle auto-lock — re-arm the preempt
            // monitor so protection resumes the moment a Session ends.
            self?.preempt.medusaLockStateDidChange()
        }
        keepAwake.onTick = { [weak self] in
            self?.menuBar.refreshCountdown()
        }
        keepAwake.onKeepAwakeFailed = { [weak self] in
            // Only the Lock path alerts via the lock's once-per-lock latch;
            // a bare Session failure surfaces here.
            guard self?.lock.isLocked != true else { return }
            self?.alertKeepAwakeFailed()
        }

        menuBar.keepAwake = keepAwake
        menuBar.isLocked = { [weak lock] in lock?.isLocked ?? false }
        menuBar.onLock = { [weak self] in self?.performLockToggle() }
        menuBar.onSettings = { [weak self] in self?.showSettings() }
        menuBar.onQuickStart = { [weak self] in self?.performKeepAwakeToggle() }
        menuBar.onStartSession = { [weak self] end, level in
            self?.keepAwake.startSession(end: end, level: level)
        }
        menuBar.onExtendSession = { [weak self] minutes in
            self?.keepAwake.extend(minutes: minutes)
        }
        menuBar.onStopSession = { [weak self] in
            self?.keepAwake.stopSession()
        }
        menuBar.onUntilPicked = { [weak self] in self?.pickUntilTime() }
        menuBar.onCustomPicked = { [weak self] in self?.pickCustomDuration() }

        hotKey.onTrigger = { [weak self] in self?.performLockToggle() }
        hotKey.start()
        keepAwakeHotKey.onTrigger = { [weak self] in self?.performKeepAwakeToggle() }
        keepAwakeHotKey.start()

        preempt.isMedusaLocked = { [weak lock] in lock?.isLocked ?? false }
        preempt.isSessionActive = { [weak keepAwake] in keepAwake?.hasSession ?? false }
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
        if AppSettings.keepAwakeStartAtLaunch, !lock.isLocked {
            keepAwake.startSession(
                end: AppSettings.keepAwakeDefaultEnd,
                level: AppSettings.keepAwakeDefaultLevel
            )
        }
    }

    private func performLockToggle() {
        guard Permissions.allGranted else {
            showSettings(tab: .permissions)
            return
        }
        lock.toggle()
    }

    /// Quick start / hotkey: toggle a Session with the Default duration.
    /// Ignored while locked (Sessions start only while unlocked).
    private func performKeepAwakeToggle() {
        guard !lock.isLocked else { return }
        if keepAwake.hasSession {
            keepAwake.stopSession()
        } else {
            keepAwake.startSession(
                end: AppSettings.keepAwakeDefaultEnd,
                level: AppSettings.keepAwakeDefaultLevel
            )
        }
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

    // MARK: Until… / Custom…

    private func pickUntilTime() {
        guard !lock.isLocked else { return }
        let picker = NSDatePicker()
        picker.datePickerElements = .hourMinute
        picker.dateValue = Date().addingTimeInterval(3600)
        let alert = NSAlert()
        alert.messageText = "Keep awake until…"
        alert.informativeText = "The Mac stays awake until this clock time."
        alert.accessoryView = picker
        alert.addButton(withTitle: "Start")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        keepAwake.startSession(
            end: .until(picker.dateValue),
            level: AppSettings.keepAwakeDefaultLevel
        )
    }

    private func pickCustomDuration() {
        guard !lock.isLocked else { return }
        let hoursField = NSTextField(string: "1")
        hoursField.placeholderString = "h"
        let minutesField = NSTextField(string: "30")
        minutesField.placeholderString = "m"
        let stack = NSStackView(views: [hoursField, minutesField])
        stack.orientation = .horizontal
        stack.spacing = 8
        hoursField.widthAnchor.constraint(equalToConstant: 64).isActive = true
        minutesField.widthAnchor.constraint(equalToConstant: 64).isActive = true
        let alert = NSAlert()
        alert.messageText = "Keep awake for…"
        alert.informativeText = "Hours and minutes from now."
        alert.accessoryView = stack
        alert.addButton(withTitle: "Start")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let hours = max(0, Int(hoursField.stringValue) ?? 0)
        let minutes = max(0, Int(minutesField.stringValue) ?? 0)
        let total = hours * 3600 + minutes * 60
        guard total > 0 else { return }
        keepAwake.startSession(
            end: .duration(TimeInterval(total)),
            level: AppSettings.keepAwakeDefaultLevel
        )
    }

    // MARK: Notifications

    /// The Extend action on the ending-soon nudge buys 30 more minutes.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if response.actionIdentifier == KeepAwakeNotifier.extendActionID {
            keepAwake.extend(minutes: 30)
        }
        completionHandler()
    }

    /// Show notifications even when Medusa is the active app (it will be —
    /// the user is watching output hands-off when the nudge matters).
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
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
