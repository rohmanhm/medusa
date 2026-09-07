import Foundation

/// How much of the Mac a Hold keeps on. Display awake keeps the screen lit
/// and the system running; System awake lets the screen sleep but keeps the
/// system running. The strongest level among live Holds wins.
enum AwakeLevel: String {
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

    /// The absolute end time. Durations become deadlines at start; a past
    /// clock time means tomorrow (the picker only offers future times, this
    /// is the backstop so a stale date can never end a Session instantly).
    func deadline(from now: Date = Date()) -> Date? {
        switch self {
        case .indefinitely:
            return nil
        case .duration(let interval):
            return now.addingTimeInterval(max(1, interval))
        case .until(let date):
            return date > now ? date : date.addingTimeInterval(24 * 3600)
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

/// Pure decision surface for Keep Awake. Production `KeepAwakeController`
/// must call through these helpers — if a deadline, guard, or composition
/// rule lives only in the controller, the harness can't go red on it.
enum KeepAwakePolicy {
    /// Strongest live level wins. The Lock hold is always Display awake (the
    /// Shield must be visible). Nil means nothing is holding — release.
    static func resolveLevel(session: AwakeLevel?, lockHold: Bool) -> AwakeLevel? {
        if lockHold { return .display }
        return session
    }

    static func deadlinePassed(deadline: Date?, now: Date) -> Bool {
        guard let deadline else { return false }
        return now >= deadline
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

    /// Sessions-only v1 guard: on battery and enabled, trip at ≤ threshold
    /// percent OR the OS Final warning (~10 min real runtime on tired cells).
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

    /// Sessions start only while unlocked; the keep-awake hotkey is ignored
    /// while locked (the menu isn't reachable under the Shield either).
    static func sessionShouldStart(isLocked: Bool) -> Bool { !isLocked }
    static func hotkeyAllowed(isLocked: Bool) -> Bool { !isLocked }

    /// Active menu header. Verbose `1 h 23 m` phrasing lives here only — the
    /// bar-adjacent countdown uses the compact `1:23` format.
    static func headerText(
        deadline: Date?,
        indefinite: Bool,
        untilTime: Bool,
        untilDate: Date?,
        lockAlso: Bool,
        now: Date
    ) -> String {
        let base: String
        if indefinite || deadline == nil {
            base = "Awake · indefinitely"
        } else if untilTime, let untilDate {
            base = "Awake · until \(Self.untilTimeFormatter.string(from: untilDate))"
        } else if let deadline {
            let remaining = max(0, deadline.timeIntervalSince(now))
            base = "Awake · \(Self.verboseRemaining(remaining)) left"
        } else {
            base = "Awake · indefinitely"
        }
        return lockAlso ? base + " · also: lock" : base
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

    private static func verboseRemaining(_ remaining: TimeInterval) -> String {
        let total = Int(remaining)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours > 0 { return "\(hours) h \(minutes) m" }
        if minutes > 0 { return "\(minutes) m" }
        return "less than a minute"
    }

    private static let untilTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()
}
