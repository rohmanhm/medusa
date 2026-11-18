import AppKit
import CoreGraphics
import IOKit.ps

/// One engine, many Holds: owns the single OS power assertion while any Hold
/// is live — the user's Session, the Lock hold the Lock places while engaged,
/// and the Schedule hold an open Schedule window places. Strongest Awake
/// level wins.
///
/// Deadlines are absolute end times. While a Hold is live, a ≤ 1 s
/// self-correcting tick that re-reads the wall clock is the sole authority
/// (timers stop during sleep), re-evaluated on wake and on system-clock
/// change. With nothing held the engine sleeps until the next Schedule
/// window opens. The kernel timeout is a fail-safe outer bound only,
/// re-derived on every evaluation.
final class KeepAwakeController {
    struct BatteryStatus: Equatable {
        var onBattery = false
        var percent: Double?
        var warningFinal = false
    }

    private let power = PowerAssertion()
    /// The clock, the stored Schedules, and the power source are the engine's
    /// system boundaries. The app takes the defaults.
    private let now: () -> Date
    private let loadSchedules: () -> [KeepAwakeSchedule]
    private let readBattery: () -> BatteryStatus

    private(set) var session: KeepAwakeSession?
    private var lockHold: AwakeLevel?
    private var schedules: [KeepAwakeSchedule]
    /// Set by "Pause Schedule": the end of the window that was open then.
    private var schedulePausedUntil: Date?
    private(set) var scheduleStatus: ScheduleStatus = .idle

    private let timer: DispatchSourceTimer
    /// The engine starts ticking so its first evaluation happens once the app
    /// has finished wiring it, then settles into whatever the state needs.
    private var tickPlan: TickPlan = .everySecond
    private var appliedLevel: AwakeLevel?
    /// The Hold horizon the live assertion's kernel timeout was set from.
    private var appliedBound: Date?
    private var lastRetime = Date.distantPast
    private var lastBatteryCheck = Date.distantPast
    private var cachedBattery = BatteryStatus()
    private var lastUserActivity = Date.distantPast
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

    init(
        now: @escaping () -> Date = Date.init,
        schedules: @escaping () -> [KeepAwakeSchedule] = { AppSettings.keepAwakeSchedules },
        battery: @escaping () -> BatteryStatus = KeepAwakeController.systemBattery
    ) {
        self.now = now
        loadSchedules = schedules
        readBattery = battery
        self.schedules = schedules()

        timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 1, repeating: 1.0, leeway: .milliseconds(200))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()

        let workspace = NSWorkspace.shared.notificationCenter
        for name in [
            NSWorkspace.didWakeNotification,
            NSWorkspace.screensDidSleepNotification,
            NSWorkspace.screensDidWakeNotification
        ] {
            workspace.addObserver(self, selector: #selector(refresh), name: name, object: nil)
        }
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(refresh),
            name: .NSSystemClockDidChange,
            object: nil
        )
        for name in [UserDefaults.didChangeNotification, .NSSystemTimeZoneDidChange] {
            NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: name, object: nil)
        }
    }

    deinit {
        timer.cancel()
        power.end()
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        DistributedNotificationCenter.default().removeObserver(self)
    }

    // MARK: Sessions

    var hasSession: Bool { session != nil }
    var hasLockHold: Bool { lockHold != nil }

    var effectiveLevel: AwakeLevel? {
        KeepAwakePolicy.resolveLevel(
            session: session?.level,
            lockHold: lockHold,
            schedule: scheduleStatus.heldLevel
        )
    }

    /// Start (or replace) a Session. Ignored while locked.
    func startSession(end: KeepAwakeEndCondition, level: AwakeLevel) {
        guard KeepAwakePolicy.sessionShouldStart(isLocked: isLocked?() ?? false) else { return }
        let session = KeepAwakeSession(
            deadline: end.deadline(from: now()),
            level: level,
            endsAtClockTime: end.isUntilTime
        )
        self.session = session
        soonNotified = false
        Log.keepAwake.notice(
            "session started level=\(level.rawValue, privacy: .public) deadline=\(String(describing: session.deadline), privacy: .public)"
        )
        KeepAwakeNotifier.requestAuthorizationIfNeeded()
        reevaluate()
        onStateChange?()
    }

    /// Manual stop — never notifies.
    func stopSession() {
        guard session != nil else { return }
        session = nil
        soonNotified = false
        Log.keepAwake.notice("session stopped by the user")
        reevaluate()
        onStateChange?()
    }

    /// Buy more time on a live Session (menu or notification action). An
    /// indefinite Session has no end to push, so it stays indefinite.
    func extend(minutes: Int) {
        guard var current = session, let deadline = current.deadline else { return }
        current.deadline = max(deadline, now()).addingTimeInterval(TimeInterval(minutes * 60))
        // An extended Until… Session ends at the pushed time, which is no
        // longer the clock time the user picked. The copy stays honest.
        current.endsAtClockTime = false
        session = current
        soonNotified = false
        reevaluate()
        onStateChange?()
    }

    // MARK: Lock hold

    /// The Lock places this while engaged (iff it should hold keep-awake), at
    /// the level its Shield needs, and withdraws it with nil on unlock.
    /// Idempotent. Returns whether the promise holds afterward.
    @discardableResult
    func setLockHold(_ level: AwakeLevel?) -> Bool {
        lockHold = level
        reevaluate()
        onStateChange?()
        return effectiveLevel == nil || power.held
    }

    // MARK: Schedule hold

    /// Let the Mac sleep for the rest of the open Schedule window. The next
    /// window opens as usual.
    func pauseSchedule() {
        guard case .holding(let window) = scheduleStatus else { return }
        schedulePausedUntil = window.end
        reevaluate()
    }

    func resumeSchedule() {
        guard schedulePausedUntil != nil else { return }
        schedulePausedUntil = nil
        reevaluate()
    }

    // MARK: Derived UI

    func headerText() -> String? {
        KeepAwakePolicy.headerText(
            session: session,
            schedule: scheduleStatus,
            lockHold: hasLockHold,
            now: now()
        )
    }

    // MARK: Evaluation

    /// Re-read everything that changes behind the engine's back (stored
    /// Schedules, the power source), then evaluate. Wake, display sleep and
    /// wake, clock changes, and settings changes all land here.
    @objc func refresh() {
        lastBatteryCheck = .distantPast
        schedules = loadSchedules()
        reevaluate()
    }

    private func tick() {
        // A one-shot plan has fired. Clear it so the evaluation below re-arms
        // the timer even when it lands on the same plan.
        if case .at = tickPlan { tickPlan = .idle }
        reevaluate()
        onTick?()
    }

    private func reevaluate() {
        let now = now()
        let window = SchedulePolicy.window(schedules: schedules, at: now)
        let batteryTripped = (session != nil || window != nil) && isBatteryTripped(now: now)

        // Un-chosen Session ends first: battery, then deadline.
        var ended: KeepAwakeEndReason?
        if let current = session {
            ended = KeepAwakePolicy.endReason(
                deadline: current.deadline,
                deadlineIsUntilTime: current.endsAtClockTime,
                now: now,
                batteryTripped: batteryTripped
            )
            if ended != nil {
                session = nil
                soonNotified = false
            } else if AppSettings.keepAwakeSoonNotify, !soonNotified, let deadline = current.deadline {
                // Opt-in ending-soon nudge with Extend.
                let lead = TimeInterval(max(1, AppSettings.keepAwakeSoonMinutes) * 60)
                if now >= deadline.addingTimeInterval(-lead), now < deadline {
                    soonNotified = true
                    KeepAwakeNotifier.postEndingSoon(deadline: deadline)
                }
            }
        }

        if let pausedUntil = schedulePausedUntil, now >= pausedUntil {
            schedulePausedUntil = nil
        }
        let status = KeepAwakePolicy.scheduleStatus(
            window: window,
            pausedUntil: schedulePausedUntil,
            batteryTripped: batteryTripped,
            now: now
        )
        let scheduleChanged = status != scheduleStatus
        scheduleStatus = status

        applyAssertion(now: now)
        wakeDisplaysIfNeeded(now: now)
        retime(now: now)

        if scheduleChanged {
            Log.keepAwake.notice("schedule \(String(describing: status), privacy: .public)")
        }
        if ended != nil || scheduleChanged {
            onStateChange?()
        }
        if let ended {
            Log.keepAwake.notice("session ended reason=\(String(describing: ended), privacy: .public)")
            if AppSettings.keepAwakeEndedNotify {
                KeepAwakeNotifier.postEnded(reason: ended, stillAwake: effectiveLevel != nil)
            }
            onSessionEnded?(ended)
        }
    }

    /// Hold the effective level, releasing when nothing holds.
    ///
    /// The kernel timeout disarms a hung Medusa, so it may only exist when
    /// every live Hold has an end, and it must track the latest one. A Hold
    /// that outlived a finite Session used to inherit that Session's timeout:
    /// the kernel turned the shared assertion off a minute after the Session
    /// ended while the Lock still believed it was holding.
    private func applyAssertion(now: Date) {
        guard let effective = effectiveLevel else {
            if power.held {
                power.end()
                Log.keepAwake.notice("assertion released")
            }
            appliedLevel = nil
            appliedBound = nil
            failedWarned = false
            return
        }
        let bound = KeepAwakePolicy.kernelBound(
            session: session,
            lockHold: hasLockHold,
            schedule: scheduleStatus
        )
        let timeout = bound.map { max(60, $0.timeIntervalSince(now) + 60) } ?? 0
        let boundednessChanged = (bound == nil) != (appliedBound == nil)
        if appliedLevel != effective || !power.held || boundednessChanged {
            power.end()
            appliedLevel = power.begin(level: effective, timeoutSeconds: timeout) ? effective : nil
            lastRetime = now
            Log.keepAwake.notice(
                "assertion level=\(effective.rawValue, privacy: .public) held=\(self.power.held, privacy: .public) bounded=\(bound != nil, privacy: .public)"
            )
        } else if timeout > 0, bound != appliedBound || now.timeIntervalSince(lastRetime) >= 60 {
            power.retimeout(timeout)
            lastRetime = now
        }
        appliedBound = bound
        if !power.held, !failedWarned {
            failedWarned = true
            DispatchQueue.main.async { [weak self] in self?.onKeepAwakeFailed?() }
        }
    }

    /// Display awake promises every panel stays lit. Poll `CGDisplayIsAsleep`
    /// (per-display — `screensDidSleep` only fires when *all* screens sleep)
    /// and declare user activity so a TV that went dark on its own comes back
    /// while the built-in stayed on.
    private func wakeDisplaysIfNeeded(now: Date) {
        let level = effectiveLevel
        guard KeepAwakePolicy.shouldWakeDisplays(
            level: level,
            anyDisplayAsleep: level == .display && Self.anyDisplayAsleep()
        ) else { return }
        guard now.timeIntervalSince(lastUserActivity) >= 5 else { return }
        lastUserActivity = now
        power.declareUserActivity()
    }

    private static func anyDisplayAsleep() -> Bool {
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        guard count > 0 else { return false }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &ids, &count)
        return (0..<Int(count)).contains { CGDisplayIsAsleep(ids[$0]) != 0 }
    }

    /// Re-arm the one timer for what the state needs now.
    private func retime(now: Date) {
        let plan = KeepAwakePolicy.tickPlan(
            holding: effectiveLevel != nil,
            schedule: scheduleStatus,
            nextScheduleStart: SchedulePolicy.nextStart(schedules: schedules, after: now),
            now: now
        )
        guard plan != tickPlan else { return }
        tickPlan = plan
        switch plan {
        case .everySecond:
            timer.schedule(deadline: .now() + 1, repeating: 1.0, leeway: .milliseconds(200))
        case .at(let date):
            // Wall-clock deadline: it keeps counting through sleep and follows
            // clock changes. Half a second late, so the tick lands inside the
            // window it is waiting for.
            let delay = max(0, date.timeIntervalSince(now)) + 0.5
            timer.schedule(wallDeadline: .now() + delay, repeating: .never, leeway: .seconds(1))
        case .idle:
            timer.schedule(deadline: .distantFuture)
        }
    }

    // MARK: Battery

    private func isBatteryTripped(now: Date) -> Bool {
        if now.timeIntervalSince(lastBatteryCheck) >= 15 || now < lastBatteryCheck {
            lastBatteryCheck = now
            cachedBattery = readBattery()
        }
        return KeepAwakePolicy.batteryShouldTrip(
            enabled: AppSettings.keepAwakeGuardEnabled,
            onBattery: cachedBattery.onBattery,
            percent: cachedBattery.percent,
            warningFinal: cachedBattery.warningFinal,
            threshold: AppSettings.keepAwakeGuardThreshold
        )
    }

    static func systemBattery() -> BatteryStatus {
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
