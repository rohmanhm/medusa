import Foundation

/// How much of the Mac a Hold keeps on. Display awake keeps the screen lit
/// and the system running; System awake lets the screen sleep but keeps the
/// system running. The strongest level among live Holds wins.
enum AwakeLevel: String, Codable {
    case display
    case system

    var rank: Int {
        switch self {
        case .display: return 2
        case .system: return 1
        }
    }
}

/// A Session's End condition in CONTEXT.md terms. V1 ships three; "while a
/// process runs" is deferred to the follow-up (see the while-running ticket).
enum KeepAwakeEndCondition: Equatable {
    case indefinitely
    case duration(TimeInterval)
    case until(Date)

    /// The absolute end time. Durations become deadlines at start. `until`
    /// carries a clock time: only its hour and minute count, and the deadline
    /// is the next time the clock reads that, so a picker that kept
    /// tomorrow's date still ends tonight and a past time means tomorrow.
    func deadline(from now: Date = Date(), calendar: Calendar = .current) -> Date? {
        switch self {
        case .indefinitely:
            return nil
        case .duration(let interval):
            return now.addingTimeInterval(max(1, interval))
        case .until(let date):
            let clockTime = calendar.dateComponents([.hour, .minute], from: date)
            return calendar.nextDate(after: now, matching: clockTime, matchingPolicy: .nextTime)
        }
    }

    var isUntilTime: Bool {
        if case .until = self { return true }
        return false
    }
}

/// Why a Session ended without the user's hand (manual Stop never notifies).
enum KeepAwakeEndReason: Equatable {
    case elapsed
    case timePassed
    case battery
}

/// A live Session: when it ends (nil for indefinitely), how much it keeps on,
/// and whether the user asked for a clock time rather than a duration.
struct KeepAwakeSession: Equatable {
    var deadline: Date?
    var level: AwakeLevel
    var endsAtClockTime: Bool
}

/// Where the Schedules stand right now.
enum ScheduleStatus: Equatable {
    /// No window is open.
    case idle
    /// A window is open and its Schedule hold is live.
    case holding(SchedulePolicy.Window)
    /// A window is open, but the user let the Mac sleep until it ends.
    case paused(until: Date)
    /// A window is open, but the Battery guard keeps its hold off.
    case batteryLow

    var heldLevel: AwakeLevel? {
        if case .holding(let window) = self { return window.level }
        return nil
    }
}

/// When the engine next has to look at the clock.
enum TickPlan: Equatable {
    /// A Hold is live: deadlines, the Battery guard, and window ends are
    /// checked against the wall clock every second.
    case everySecond
    /// Nothing holds, but something will change at this time.
    case at(Date)
    /// Nothing holds and nothing is scheduled. The engine sleeps.
    case idle
}

/// Pure decision surface for Keep Awake. Production `KeepAwakeController`
/// must call through these helpers — if a deadline, guard, or composition
/// rule lives only in the controller, the harness can't go red on it.
enum KeepAwakePolicy {
    /// Strongest live level wins. Nil means nothing is holding — release.
    static func resolveLevel(session: AwakeLevel?, lockHold: AwakeLevel?, schedule: AwakeLevel? = nil) -> AwakeLevel? {
        [session, lockHold, schedule].compactMap { $0 }.max { $0.rank < $1.rank }
    }

    /// A Schedule hold is live while a window is open, unless the user paused
    /// it for the rest of that window or the Battery guard has tripped.
    static func scheduleStatus(
        window: SchedulePolicy.Window?,
        pausedUntil: Date?,
        batteryTripped: Bool,
        now: Date
    ) -> ScheduleStatus {
        guard let window else { return .idle }
        if let pausedUntil, now < pausedUntil { return .paused(until: pausedUntil) }
        return batteryTripped ? .batteryLow : .holding(window)
    }

    /// An idle engine should not wake once a second for years. With no Hold
    /// live it sleeps until the next thing that can change: a window opening,
    /// a pause running out, or (while the Battery guard holds a Schedule off)
    /// a look at the power source a minute from now.
    static func tickPlan(
        holding: Bool,
        schedule: ScheduleStatus,
        nextScheduleStart: Date?,
        now: Date
    ) -> TickPlan {
        if holding { return .everySecond }
        var changes = [nextScheduleStart].compactMap { $0 }
        switch schedule {
        case .paused(let until): changes.append(until)
        case .batteryLow: changes.append(now.addingTimeInterval(60))
        case .idle, .holding: break
        }
        return changes.min().map(TickPlan.at) ?? .idle
    }

    /// The moment after which no live Hold needs the Mac awake, or nil when
    /// one of them is open-ended (an indefinite Session, the Lock hold). The
    /// kernel timeout that disarms a hung Medusa is set from this, so it can
    /// never cut short a Hold that is still owed.
    static func kernelBound(session: KeepAwakeSession?, lockHold: Bool, schedule: ScheduleStatus) -> Date? {
        if lockHold { return nil }
        var ends: [Date] = []
        if let session {
            guard let deadline = session.deadline else { return nil }
            ends.append(deadline)
        }
        if case .holding(let window) = schedule { ends.append(window.end) }
        return ends.max()
    }

    /// Which un-chosen end fired, if any. Battery wins ties (it is checked
    /// first so a dead laptop never waits for a deadline).
    static func endReason(
        deadline: Date?,
        deadlineIsUntilTime: Bool,
        now: Date,
        batteryTripped: Bool
    ) -> KeepAwakeEndReason? {
        if batteryTripped { return .battery }
        guard let deadline, now >= deadline else { return nil }
        return deadlineIsUntilTime ? .timePassed : .elapsed
    }

    /// On battery and enabled, trip at ≤ threshold percent OR the OS Final
    /// warning (~10 min real runtime on tired cells). Covers Sessions and
    /// Schedules: both leave a Mac awake with nobody watching the charge.
    static func batteryShouldTrip(
        enabled: Bool,
        onBattery: Bool,
        percent: Double?,
        warningFinal: Bool,
        threshold: Int
    ) -> Bool {
        guard enabled, onBattery else { return false }
        if let percent, percent <= Double(threshold) { return true }
        return warningFinal
    }

    /// Display awake promises every panel stays lit. `PreventUserIdleDisplaySleep`
    /// does not turn a display back on once it's off (IOPMLib) and does not
    /// cover a panel that slept on its own (TVs, HDMI dropout). System awake
    /// lets screens sleep; nothing holding means ignore.
    static func shouldWakeDisplays(level: AwakeLevel?, anyDisplayAsleep: Bool) -> Bool {
        level == .display && anyDisplayAsleep
    }

    /// Sessions start only while unlocked; the keep-awake hotkey is ignored
    /// while locked (the menu isn't reachable under the Shield either).
    static func sessionShouldStart(isLocked: Bool) -> Bool { !isLocked }
    static func hotkeyAllowed(isLocked: Bool) -> Bool { !isLocked }

    /// The disabled header line of the Keep Awake menu: the Hold the user
    /// would name first, then the others, so nothing about why the Mac is
    /// awake is hidden. Nil when nothing holds. Verbose `1 h 23 m` phrasing
    /// lives here only — the bar-adjacent countdown uses the compact format.
    static func headerText(
        session: KeepAwakeSession?,
        schedule: ScheduleStatus,
        lockHold: Bool,
        now: Date,
        clockTime: (Date) -> String = KeepAwakePolicy.clockTime
    ) -> String? {
        let base: String
        var others: [String] = []
        if let session {
            if let deadline = session.deadline {
                base = session.endsAtClockTime
                    ? "Awake · until \(clockTime(deadline))"
                    : "Awake · \(verboseRemaining(max(0, deadline.timeIntervalSince(now)))) left"
            } else {
                base = "Awake · indefinitely"
            }
            if schedule.heldLevel != nil { others.append("schedule") }
        } else if case .holding(let window) = schedule {
            base = "Awake · schedule until \(clockTime(window.end))"
        } else if lockHold {
            return "Awake · lock"
        } else {
            return nil
        }
        if lockHold { others.append("lock") }
        return others.isEmpty ? base : base + " · also: " + others.joined(separator: ", ")
    }

    /// A second menu line for a Schedule whose window is open but which is
    /// not holding, so the icon going idle inside a window is explained.
    static func scheduleNote(
        _ status: ScheduleStatus,
        clockTime: (Date) -> String = KeepAwakePolicy.clockTime
    ) -> String? {
        switch status {
        case .paused(let until): return "Schedule paused until \(clockTime(until))"
        case .batteryLow: return "Schedule waiting · battery low"
        case .idle, .holding: return nil
        }
    }

    /// A clock time the way the user's locale writes it ("5:00 PM", "17.00").
    static func clockTime(_ date: Date) -> String {
        clockTimeFormatter.string(from: date)
    }

    /// Compact `1:23` countdown for beside the icon. Format (not font) fixes
    /// width jitter. Nil for indefinite Sessions (nothing to count down).
    static func countdownText(deadline: Date?, now: Date) -> String? {
        guard let deadline else { return nil }
        let total = max(0, Int(deadline.timeIntervalSince(now).rounded(.up)))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }

    /// The text beside the status icon: the countdown of a finite Session
    /// when the user turned it on, nothing otherwise.
    static func barCountdown(enabled: Bool, deadline: Date?, now: Date) -> String? {
        enabled ? countdownText(deadline: deadline, now: now) : nil
    }

    private static func verboseRemaining(_ remaining: TimeInterval) -> String {
        let total = Int(remaining)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours > 0 { return "\(hours) h \(minutes) m" }
        if minutes > 0 { return "\(minutes) m" }
        return "less than a minute"
    }

    private static let clockTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()
}
