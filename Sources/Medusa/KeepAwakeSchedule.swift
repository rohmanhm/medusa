import Foundation

/// A Schedule in CONTEXT.md terms: a weekly window during which Medusa keeps
/// the Mac awake on its own.
///
/// A Schedule is a statement about clock time, not an event. Whether it holds
/// is a pure function of "now", so it needs no start trigger: a Mac that
/// launches, wakes, or changes time zone inside the window is covered at once.
struct KeepAwakeSchedule: Codable, Equatable, Identifiable {
    static let minutesPerDay = 24 * 60

    var id = UUID()
    var isEnabled = true
    /// The days the window starts on, as `Calendar` weekday numbers
    /// (1 = Sunday … 7 = Saturday).
    var weekdays: Set<Int> = [2, 3, 4, 5, 6]
    /// Minutes after midnight, `0 ..< 1440`.
    var startMinute = 9 * 60
    /// Minutes after midnight. At or before `startMinute` the window runs
    /// into the next day, and equal to it the window lasts 24 hours.
    var endMinute = 18 * 60
    var level: AwakeLevel = .display

    var endsNextDay: Bool { endMinute <= startMinute }

    /// Stored Schedules are user data on disk. Read them tolerantly: anything
    /// that does not decode is no Schedule, and out-of-range fields are
    /// clamped, so nothing past this point has to doubt a value.
    static func decodeList(from data: Data?) -> [KeepAwakeSchedule] {
        guard let data, let list = try? JSONDecoder().decode([KeepAwakeSchedule].self, from: data) else {
            return []
        }
        return list.map { schedule in
            var clean = schedule
            clean.weekdays = schedule.weekdays.filter((1...7).contains)
            clean.startMinute = min(max(0, schedule.startMinute), minutesPerDay - 1)
            clean.endMinute = min(max(0, schedule.endMinute), minutesPerDay - 1)
            return clean
        }
    }

    static func encodeList(_ list: [KeepAwakeSchedule]) -> Data {
        (try? JSONEncoder().encode(list)) ?? Data()
    }
}

/// Pure decisions about Schedules.
enum SchedulePolicy {
    /// What the Schedules ask for at one instant: the strongest Awake level
    /// among the windows that are open, and when that level ends.
    struct Window: Equatable {
        var level: AwakeLevel
        var end: Date
    }

    static func window(
        schedules: [KeepAwakeSchedule],
        at now: Date,
        calendar: Calendar = .current
    ) -> Window? {
        // A window open now started today, or yesterday if it runs overnight.
        let open = intervals(of: schedules, dayOffsets: -1...0, around: now, calendar: calendar)
            .filter { $0.interval.start <= now && now < $0.interval.end }
        guard let level = open.map(\.level).max(by: { $0.rank < $1.rank }),
              let end = open.filter({ $0.level == level }).map(\.interval.end).max()
        else { return nil }
        return Window(level: level, end: end)
    }

    /// The next time any Schedule opens, for arming one timer instead of
    /// polling the clock.
    static func nextStart(
        schedules: [KeepAwakeSchedule],
        after now: Date,
        calendar: Calendar = .current
    ) -> Date? {
        intervals(of: schedules, dayOffsets: 0...7, around: now, calendar: calendar)
            .map(\.interval.start)
            .filter { $0 > now }
            .min()
    }

    private static func intervals(
        of schedules: [KeepAwakeSchedule],
        dayOffsets: ClosedRange<Int>,
        around now: Date,
        calendar: Calendar
    ) -> [(level: AwakeLevel, interval: DateInterval)] {
        let today = calendar.startOfDay(for: now)
        return schedules.filter(\.isEnabled).flatMap { schedule in
            dayOffsets.compactMap { offset -> (level: AwakeLevel, interval: DateInterval)? in
                guard let day = calendar.date(byAdding: .day, value: offset, to: today),
                      let interval = interval(of: schedule, startingOn: day, calendar: calendar)
                else { return nil }
                return (schedule.level, interval)
            }
        }
    }

    /// The window a Schedule opens on one calendar day, in wall-clock time so
    /// a DST shift moves neither edge.
    private static func interval(
        of schedule: KeepAwakeSchedule,
        startingOn day: Date,
        calendar: Calendar
    ) -> DateInterval? {
        guard schedule.weekdays.contains(calendar.component(.weekday, from: day)),
              let endDay = calendar.date(byAdding: .day, value: schedule.endsNextDay ? 1 : 0, to: day),
              let start = clockTime(schedule.startMinute, on: day, calendar: calendar),
              let end = clockTime(schedule.endMinute, on: endDay, calendar: calendar),
              end > start
        else { return nil }
        return DateInterval(start: start, end: end)
    }

    private static func clockTime(_ minute: Int, on day: Date, calendar: Calendar) -> Date? {
        calendar.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: day)
    }
}
