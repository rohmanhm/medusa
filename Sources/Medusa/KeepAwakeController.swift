import AppKit
import IOKit.ps

/// One engine, many Holds: owns the single OS power assertion while any Hold
/// is live — the user's Session plus the Lock hold the Lock places while
/// engaged. Strongest Awake level wins; the Lock hold is always Display.
///
/// Deadlines are absolute end times. The ≤ 1 s self-correcting tick that
/// re-reads the wall clock is the sole authority (timers stop during sleep),
/// re-evaluated on wake and on system-clock change. The kernel timeout is a
/// fail-safe outer bound only, re-derived from `deadline − now` on every
/// wake and Extend.
final class KeepAwakeController {
    struct Session {
        var deadline: Date?
        var level: AwakeLevel
        var untilTime: Bool
        var untilDate: Date?
    }

    private let power = PowerAssertion()
    private(set) var session: Session?
    private var lockHold = false

    private var timer: DispatchSourceTimer?
    private var appliedLevel: AwakeLevel?
    private var lastRetime = Date.distantPast
    private var lastBatteryCheck = Date.distantPast
    private var soonNotified = false
    private var failedWarned = false

    /// Fired on session / hold / level changes (menu + icon refresh).
    var onStateChange: (() -> Void)?
    /// Fired every tick so the countdown text can refresh.
    var onTick: (() -> Void)?
    /// Keep-awake was needed but the kernel refused. Fired at most once per
    /// episode (resets when nothing is holding).
    var onKeepAwakeFailed: (() -> Void)?
    /// A Session ended without the user's hand (for the ended notification).
    var onSessionEnded: ((KeepAwakeEndReason) -> Void)?

    /// Reads `isLocked` for hotkey/start gating. Wired by the app delegate;
    /// headless users leave it nil (treated as unlocked).
    var isLocked: (() -> Bool)?

    init() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 1, repeating: 1.0, leeway: .milliseconds(200))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer

        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(
            self,
            selector: #selector(reevaluateFromNotification),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(reevaluateFromNotification),
            name: .NSSystemClockDidChange,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(reevaluateFromNotification),
            name: UserDefaults.didChangeNotification,
            object: nil
        )
    }

    deinit {
        timer?.cancel()
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        DistributedNotificationCenter.default().removeObserver(self)
    }

    // MARK: Sessions

    var hasSession: Bool { session != nil }
    var hasLockHold: Bool { lockHold }

    var effectiveLevel: AwakeLevel? {
        KeepAwakePolicy.resolveLevel(session: session?.level, lockHold: lockHold)
    }

    /// Start (or replace) a Session. Ignored while locked.
    func startSession(end: KeepAwakeEndCondition, level: AwakeLevel) {
        guard KeepAwakePolicy.sessionShouldStart(isLocked: isLocked?() ?? false) else { return }
        let now = Date()
        session = Session(
            deadline: end.deadline(from: now),
            level: level,
            untilTime: end.isUntilTime,
            untilDate: end.isUntilTime ? end.deadline(from: now) : nil
        )
        soonNotified = false
        KeepAwakeNotifier.requestAuthorizationIfNeeded()
        reevaluate()
        onStateChange?()
    }

    /// Manual stop — never notifies.
    func stopSession() {
        guard session != nil else { return }
        session = nil
        soonNotified = false
        reevaluate()
        onStateChange?()
    }

    /// Buy more time on a live Session (menu or notification action).
    func extend(minutes: Int) {
        guard var current = session else { return }
        let now = Date()
        let base = max(current.deadline ?? now, now)
        let next = base.addingTimeInterval(TimeInterval(minutes * 60))
        current.deadline = next
        if current.untilTime {
            // An extended Until… Session becomes a duration Session ending at
            // the pushed time — the copy stays honest about the real end.
            current.untilTime = false
            current.untilDate = nil
        }
        session = current
        soonNotified = false
        reevaluate()
        onStateChange?()
    }

    // MARK: Lock hold

    /// The Lock places this while engaged (iff it should hold keep-awake) and
    /// withdraws it on unlock. Returns whether the promise holds afterward.
    @discardableResult
    func setLockHold(_ on: Bool) -> Bool {
        lockHold = on
        reevaluate()
        onStateChange?()
        return effectiveLevel == nil || power.held
    }

    /// Wake / reaffirm path: re-derive timeouts and re-hold. Returns whether
    /// the promise holds afterward.
    @discardableResult
    func reaffirmLockHold() -> Bool {
        lastBatteryCheck = .distantPast
        reevaluate()
        return effectiveLevel == nil || power.held
    }

    // MARK: Derived UI

    func headerText(now: Date = Date()) -> String? {
        guard let session else {
            return lockHold ? "Awake · lock" : nil
        }
        return KeepAwakePolicy.headerText(
            deadline: session.deadline,
            indefinite: session.deadline == nil,
            untilTime: session.untilTime,
            untilDate: session.untilDate,
            lockAlso: lockHold,
            now: now
        )
    }

    func countdownText(now: Date = Date()) -> String? {
        KeepAwakePolicy.countdownText(deadline: session?.deadline, now: now)
    }

    // MARK: Evaluation

    @objc private func reevaluateFromNotification() {
        lastBatteryCheck = .distantPast
        reevaluate()
    }

    private func tick() {
        reevaluate()
        onTick?()
    }

    private func reevaluate() {
        let now = Date()

        // Un-chosen ends first: battery, then deadline.
        if session != nil {
            let battery = KeepAwakePolicy.batteryShouldTrip(
                enabled: AppSettings.keepAwakeGuardEnabled,
                onBattery: batteryStatus().onBattery,
                percent: batteryStatus().percent,
                warningFinal: batteryStatus().warningFinal,
                threshold: AppSettings.keepAwakeGuardThreshold
            )
            if let reason = KeepAwakePolicy.endReason(
                deadline: session?.deadline,
                deadlineIsUntilTime: session?.untilTime ?? false,
                now: now,
                batteryTripped: battery
            ) {
                let ended = reason
                session = nil
                soonNotified = false
                applyAssertion(now: now)
                onStateChange?()
                if AppSettings.keepAwakeEndedNotify {
                    KeepAwakeNotifier.postEnded(reason: ended)
                }
                onSessionEnded?(ended)
                return
            }

            // Opt-in ending-soon nudge with Extend.
            if AppSettings.keepAwakeSoonNotify,
               !soonNotified,
               let deadline = session?.deadline
            {
                let lead = TimeInterval(max(1, AppSettings.keepAwakeSoonMinutes) * 60)
                if now >= deadline.addingTimeInterval(-lead), now < deadline {
                    soonNotified = true
                    KeepAwakeNotifier.postEndingSoon(deadline: deadline)
                }
            }
        }

        applyAssertion(now: now)
    }

    /// Hold the effective level, releasing when nothing holds. Kernel timeouts
    /// only bound finite deadlines (infinity can't be bounded); indefinite
    /// Sessions and bare Lock holds carry none — same as today's lock.
    private func applyAssertion(now: Date) {
        guard let effective = effectiveLevel else {
            if power.held { power.end() }
            appliedLevel = nil
            failedWarned = false
            return
        }
        var timeout: TimeInterval = 0
        if let deadline = session?.deadline {
            timeout = max(60, deadline.timeIntervalSince(now) + 60)
        }
        if appliedLevel != effective || !power.held {
            power.end()
            appliedLevel = power.begin(level: effective, timeoutSeconds: timeout) ? effective : nil
            lastRetime = now
        } else if timeout > 0, now.timeIntervalSince(lastRetime) >= 60 {
            power.retimeout(timeout)
            lastRetime = now
        }
        if !power.held, !failedWarned {
            failedWarned = true
            DispatchQueue.main.async { [weak self] in self?.onKeepAwakeFailed?() }
        }
    }

    // MARK: Battery

    private struct BatteryStatus {
        var onBattery = false
        var percent: Double?
        var warningFinal = false
    }

    private var cachedBattery = BatteryStatus()

    private func batteryStatus() -> BatteryStatus {
        let now = Date()
        if now.timeIntervalSince(lastBatteryCheck) < 15 { return cachedBattery }
        lastBatteryCheck = now
        cachedBattery = Self.readBattery()
        return cachedBattery
    }

    private static func readBattery() -> BatteryStatus {
        var status = BatteryStatus()
        let blob = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let providing = IOPSGetProvidingPowerSourceType(blob).takeRetainedValue() as String
        status.onBattery = providing != (kIOPSACPowerValue as String)
        let list = IOPSCopyPowerSourcesList(blob).takeRetainedValue() as [CFTypeRef]
        guard let source = list.first,
              let description = IOPSGetPowerSourceDescription(blob, source).takeUnretainedValue() as? [String: Any]
        else {
            return status
        }
        if let current = description[kIOPSCurrentCapacityKey as String] as? Double,
           let max = description[kIOPSMaxCapacityKey as String] as? Double, max > 0
        {
            status.percent = current / max * 100
        } else if let current = description[kIOPSCurrentCapacityKey as String] as? Int,
                  let max = description[kIOPSMaxCapacityKey as String] as? Int, max > 0
        {
            status.percent = Double(current) / Double(max) * 100
        }
        status.warningFinal = IOPSGetBatteryWarningLevel() == kIOPSLowBatteryWarningFinal
        return status
    }
}
