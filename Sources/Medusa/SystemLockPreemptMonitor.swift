import AppKit
import CoreGraphics

/// Watches for idle time (and best-effort ⌃⌘Q) while the opt-in preempt setting
/// is on, and asks the app to engage a Medusa auto-lock — never replaces or
/// draws over loginwindow.
///
/// Idle is the load-bearing path: HID idle via `CGEventSource`, then
/// `lock(forceKeepAwake: true)`. ⌃⌘Q is swallowed when a session tap can see it;
/// if the system still wins, race-loss warning fires once and never-trap stays
/// absolute on any later system unlock.
final class SystemLockPreemptMonitor {
    /// Fired on the main thread when idle or ⌃⌘Q should engage Medusa.
    var onAutoLock: (() -> Void)?

    /// Fired on the main thread once when macOS locked first (race loss).
    var onRaceLossWarning: (() -> Void)?

    /// Fired when the chord tap can't be installed (permissions).
    var onTapFailed: (() -> Void)?

    /// True while Medusa itself holds a lock — polling and chord intercept pause.
    var isMedusaLocked: () -> Bool = { false }

    private var idleTimer: Timer?
    private var defaultsObserver: NSObjectProtocol?
    private var systemLockObserver: NSObjectProtocol?

    private var chordTap: CFMachPort?
    private var chordSource: CFRunLoopSource?
    /// After a failed install, don't re-fire `onTapFailed` on every reconcile
    /// (UserDefaults.didChangeNotification is chatty). Cleared when the setting
    /// turns off or a tap is successfully created.
    private var chordTapInstallFailed = false

    /// Suppresses a race-loss warning for system-lock notifications that arrive
    /// around our own auto-lock attempt. Window is short.
    private var suppressRaceLossUntil: Date?

    private static let idlePollInterval: TimeInterval = 2
    /// ANSI "Q" — Control+Command+Q is the system Lock Screen shortcut.
    private static let lockScreenKeyCode: Int64 = 12

    func start() {
        guard defaultsObserver == nil else { return }
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.reconcile()
        }

        systemLockObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleSystemScreenLocked()
        }

        reconcile()
    }

    func stop() {
        if let defaultsObserver {
            NotificationCenter.default.removeObserver(defaultsObserver)
            self.defaultsObserver = nil
        }
        if let systemLockObserver {
            DistributedNotificationCenter.default().removeObserver(systemLockObserver)
            self.systemLockObserver = nil
        }
        stopIdleTimer()
        stopChordTap()
    }

    /// Call when Medusa lock state flips so idle/chord arm only while unlocked.
    func medusaLockStateDidChange() {
        reconcile()
    }

    // MARK: - Arm / disarm

    private func reconcile() {
        let enabled = AppSettings.systemLockPreemptEnabled
        let locked = isMedusaLocked()

        if enabled && !locked {
            startIdleTimer()
            startChordTapIfNeeded()
        } else {
            stopIdleTimer()
            stopChordTap()
            // Allow a fresh permissions prompt next time the user enables it.
            if !enabled { chordTapInstallFailed = false }
        }
    }

    private func startIdleTimer() {
        guard idleTimer == nil else { return }
        let timer = Timer(timeInterval: Self.idlePollInterval, repeats: true) { [weak self] _ in
            self?.pollIdle()
        }
        RunLoop.main.add(timer, forMode: .common)
        idleTimer = timer
        // Sample immediately so short thresholds aren't delayed a full period.
        pollIdle()
    }

    private func stopIdleTimer() {
        idleTimer?.invalidate()
        idleTimer = nil
    }

    private func pollIdle() {
        guard AppSettings.systemLockPreemptEnabled, !isMedusaLocked() else { return }

        // kCGAnyInputEventType == (CGEventType)(~0)
        let idle = CGEventSource.secondsSinceLastEventType(
            .hidSystemState,
            eventType: CGEventType(rawValue: ~UInt32(0))!
        )
        let threshold = AppSettings.systemLockPreemptIdleDuration
        guard LockPolicy.idlePreempt(
            enabled: true,
            isLocked: false,
            idleSeconds: idle,
            thresholdSeconds: threshold
        ) == .autoLock else { return }

        requestAutoLock()
    }

    private func requestAutoLock() {
        suppressRaceLossUntil = Date().addingTimeInterval(2)
        stopIdleTimer()
        stopChordTap()
        onAutoLock?()
        // If lock failed (permissions), re-arm while still unlocked.
        reconcile()
    }

    // MARK: - ⌃⌘Q best-effort

    private func startChordTapIfNeeded() {
        guard chordTap == nil else { return }
        // Idle preempt still runs if the chord tap can't install; only try once
        // per enablement until success or the setting turns off.
        guard !chordTapInstallFailed else { return }

        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: preemptChordTapCallback,
            userInfo: refcon
        ) else {
            chordTapInstallFailed = true
            onTapFailed?()
            return
        }

        chordTapInstallFailed = false
        chordTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        chordSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func stopChordTap() {
        if let chordTap {
            CGEvent.tapEnable(tap: chordTap, enable: false)
            if let chordSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), chordSource, .commonModes)
            }
            CFMachPortInvalidate(chordTap)
        }
        chordTap = nil
        chordSource = nil
    }

    /// Re-enable after OS auto-disable. Safe from the tap callback.
    fileprivate func reenableChordTapIfNeeded() {
        if let chordTap {
            CGEvent.tapEnable(tap: chordTap, enable: true)
        }
    }

    /// Returns true if the keyDown is ⌃⌘Q and should be swallowed.
    fileprivate func shouldSwallowLockChord(_ event: CGEvent) -> Bool {
        guard event.type == .keyDown else { return false }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        guard keyCode == Self.lockScreenKeyCode else { return false }

        let flags = event.flags
        let control = flags.contains(.maskControl)
        let command = flags.contains(.maskCommand)
        let shift = flags.contains(.maskShift)
        let option = flags.contains(.maskAlternate)
        guard control, command, !shift, !option else { return false }

        let action = LockPolicy.chordPreempt(
            enabled: AppSettings.systemLockPreemptEnabled,
            isLocked: isMedusaLocked()
        )
        guard action == .autoLock else { return false }

        DispatchQueue.main.async { [weak self] in
            self?.requestAutoLock()
        }
        return true
    }

    // MARK: - Race loss

    private func handleSystemScreenLocked() {
        if let until = suppressRaceLossUntil, Date() < until {
            return
        }
        // Never cover loginwindow. Only warn if we were free and the setting is on.
        let warn = LockPolicy.shouldWarnRaceLoss(
            enabled: AppSettings.systemLockPreemptEnabled,
            isLocked: isMedusaLocked(),
            alreadyWarned: AppSettings.systemLockPreemptWarned
        )
        guard warn else { return }
        AppSettings.systemLockPreemptWarned = true
        onRaceLossWarning?()
    }
}

private func preemptChordTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<SystemLockPreemptMonitor>.fromOpaque(refcon).takeUnretainedValue()

    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        monitor.reenableChordTapIfNeeded()
        return Unmanaged.passUnretained(event)
    }

    if monitor.shouldSwallowLockChord(event) {
        return nil
    }
    return Unmanaged.passUnretained(event)
}
