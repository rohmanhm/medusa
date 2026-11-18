import SwiftUI

/// The words the Schedule UI uses, kept out of the views so they can be read
/// and tested as plain functions of a Schedule and a clock.
enum ScheduleCopy {
    static func days(_ weekdays: Set<Int>, calendar: Calendar = .current) -> String {
        switch weekdays {
        case []: return "No days"
        case [1, 2, 3, 4, 5, 6, 7]: return "Every day"
        case [2, 3, 4, 5, 6]: return "Weekdays"
        case [1, 7]: return "Weekends"
        default:
            return orderedWeekdays(calendar)
                .filter(weekdays.contains)
                .map { calendar.shortWeekdaySymbols[$0 - 1] }
                .joined(separator: ", ")
        }
    }

    /// "Weekdays, 9:00 AM – 6:00 PM"
    static func summary(
        _ schedule: KeepAwakeSchedule,
        calendar: Calendar = .current,
        clockTime: (Date) -> String = KeepAwakePolicy.clockTime
    ) -> String {
        let start = clockTime(date(atMinute: schedule.startMinute, calendar: calendar))
        let end = clockTime(date(atMinute: schedule.endMinute, calendar: calendar))
        return "\(days(schedule.weekdays, calendar: calendar)), \(start) – \(end)"
    }

    /// What the Schedules as configured mean at this moment.
    static func status(
        schedules: [KeepAwakeSchedule],
        at now: Date,
        calendar: Calendar = .current,
        clockTime: (Date) -> String = KeepAwakePolicy.clockTime
    ) -> String {
        if let window = SchedulePolicy.window(schedules: schedules, at: now, calendar: calendar) {
            return "Inside a Schedule until \(clockTime(window.end))"
        }
        guard let next = SchedulePolicy.nextStart(schedules: schedules, after: now, calendar: calendar) else {
            return schedules.isEmpty ? "No Schedules yet" : "No Schedule is on"
        }
        let day: String
        if calendar.isDate(next, inSameDayAs: now) {
            day = "today"
        } else if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(next, inSameDayAs: tomorrow) {
            day = "tomorrow"
        } else {
            day = calendar.weekdaySymbols[calendar.component(.weekday, from: next) - 1]
        }
        return "Next starts \(day) at \(clockTime(next))"
    }

    /// Weekday numbers in the order the user's calendar lists them.
    static func orderedWeekdays(_ calendar: Calendar = .current) -> [Int] {
        (0..<7).map { (calendar.firstWeekday - 1 + $0) % 7 + 1 }
    }

    static func date(atMinute minute: Int, calendar: Calendar = .current) -> Date {
        calendar.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: Date()) ?? Date()
    }
}

struct SchedulePane: View {
    @AppStorage(AppSettings.Keys.keepAwakeSchedules) private var stored = Data()
    @AppStorage(AppSettings.Keys.keepAwakeDefaultLevel) private var defaultLevel = AwakeLevel.display.rawValue

    @State private var pendingRemoval: KeepAwakeSchedule?

    private var schedules: [KeepAwakeSchedule] {
        KeepAwakeSchedule.decodeList(from: stored)
    }

    private func update(_ change: (inout [KeepAwakeSchedule]) -> Void) {
        var list = schedules
        change(&list)
        stored = KeepAwakeSchedule.encodeList(list)
    }

    private func binding(for schedule: KeepAwakeSchedule) -> Binding<KeepAwakeSchedule> {
        Binding(
            get: { schedules.first { $0.id == schedule.id } ?? schedule },
            set: { next in
                update { list in
                    guard let index = list.firstIndex(where: { $0.id == next.id }) else { return }
                    list[index] = next
                }
            }
        )
    }

    var body: some View {
        Form {
            Section {
                TimelineView(.everyMinute) { context in
                    LabeledContent("Right now", value: ScheduleCopy.status(schedules: schedules, at: context.date))
                }
            } footer: {
                Text("A Schedule keeps your Mac awake on its own during the hours you set. "
                    + "It follows the clock, so it is on as soon as Medusa is running inside "
                    + "those hours, including after a restart or a wake.")
            }

            ForEach(schedules) { schedule in
                ScheduleSection(schedule: binding(for: schedule)) {
                    pendingRemoval = schedule
                }
            }

            Section {
                Button("Add Schedule") {
                    update { $0.append(KeepAwakeSchedule(level: AwakeLevel(rawValue: defaultLevel) ?? .display)) }
                }
            } footer: {
                Text("Outside a Schedule your Mac sleeps on its normal schedule. Closing the lid "
                    + "still sleeps it. The Battery guard covers Schedules, and you can pause "
                    + "one for the rest of its hours from the menu. Idle auto-lock is not paused "
                    + "by a Schedule.")
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .confirmationDialog(
            "Remove this Schedule?",
            isPresented: Binding(
                get: { pendingRemoval != nil },
                set: { if !$0 { pendingRemoval = nil } }
            ),
            presenting: pendingRemoval
        ) { schedule in
            Button("Remove", role: .destructive) {
                update { list in list.removeAll { $0.id == schedule.id } }
            }
        } message: { schedule in
            Text(ScheduleCopy.summary(schedule))
        }
    }
}

private struct ScheduleSection: View {
    @Binding var schedule: KeepAwakeSchedule
    let onRemove: () -> Void

    private static let levelChoices: [(level: AwakeLevel, label: String)] = [
        (.display, "Display awake (screen stays on)"),
        (.system, "System awake (screen may sleep)")
    ]

    var body: some View {
        Section {
            Toggle(ScheduleCopy.summary(schedule), isOn: $schedule.isEnabled)
            LabeledContent("Days") {
                WeekdayPicker(selection: $schedule.weekdays)
            }
            LabeledContent {
                HStack(spacing: 6) {
                    timePicker("From", \.startMinute)
                    Text("to").foregroundStyle(.secondary)
                    timePicker("Until", \.endMinute)
                }
            } label: {
                Text("Hours")
                if schedule.endsNextDay {
                    Text(schedule.startMinute == schedule.endMinute ? "A full 24 hours" : "Ends the next day")
                }
            }
            Picker("Keep", selection: $schedule.level) {
                ForEach(Self.levelChoices, id: \.level) { choice in
                    Text(choice.label).tag(choice.level)
                }
            }
            HStack {
                Spacer()
                Button("Remove Schedule…", role: .destructive, action: onRemove)
            }
        } footer: {
            if schedule.weekdays.isEmpty {
                Text("Pick at least one day, or this Schedule never starts.")
                    .foregroundStyle(.red)
            }
        }
    }

    /// A time field at its own width. The visible label is the row's
    /// ("Hours"), so each field carries its name for VoiceOver.
    private func timePicker(_ name: String, _ minute: WritableKeyPath<KeepAwakeSchedule, Int>) -> some View {
        DatePicker(
            name,
            selection: Binding(
                get: { ScheduleCopy.date(atMinute: schedule[keyPath: minute]) },
                set: { date in
                    let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                    schedule[keyPath: minute] = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
                }
            ),
            displayedComponents: .hourAndMinute
        )
        .labelsHidden()
        .fixedSize()
    }
}

/// Seven day toggles in the user's week order. Each is its own labelled
/// control, so the keyboard and VoiceOver reach every day by name.
private struct WeekdayPicker: View {
    @Binding var selection: Set<Int>

    private let calendar = Calendar.current

    var body: some View {
        HStack(spacing: 4) {
            ForEach(ScheduleCopy.orderedWeekdays(calendar), id: \.self) { weekday in
                Toggle(
                    calendar.veryShortStandaloneWeekdaySymbols[weekday - 1],
                    isOn: Binding(
                        get: { selection.contains(weekday) },
                        set: { isOn in
                            if isOn { selection.insert(weekday) } else { selection.remove(weekday) }
                        }
                    )
                )
                .toggleStyle(.button)
                .accessibilityLabel(calendar.standaloneWeekdaySymbols[weekday - 1])
                .help(calendar.standaloneWeekdaySymbols[weekday - 1])
            }
        }
    }
}
