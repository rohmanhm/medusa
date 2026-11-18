import XCTest
@testable import Medusa

/// November 2026: the 16th is a Monday, the 18th a Wednesday, the 21st a
/// Saturday.
final class SchedulePolicyTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Jakarta")!
        return calendar
    }()

    private func at(_ day: Int, _ hour: Int, _ minute: Int = 0, month: Int = 11) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
    }

    private let weekdays: Set<Int> = [2, 3, 4, 5, 6]
    private let everyDay: Set<Int> = [1, 2, 3, 4, 5, 6, 7]

    private func schedule(
        _ weekdays: Set<Int>,
        from start: Int,
        to end: Int,
        level: AwakeLevel = .display,
        isEnabled: Bool = true
    ) -> KeepAwakeSchedule {
        KeepAwakeSchedule(isEnabled: isEnabled, weekdays: weekdays, startMinute: start, endMinute: end, level: level)
    }

    private func window(_ schedules: [KeepAwakeSchedule], at now: Date) -> SchedulePolicy.Window? {
        SchedulePolicy.window(schedules: schedules, at: now, calendar: calendar)
    }

    func testAWeekdayWindowIsOpenFromItsStartUntilItsEnd() {
        let office = [schedule(weekdays, from: 9 * 60, to: 18 * 60)]

        XCTAssertNil(window(office, at: at(18, 8, 59)))
        XCTAssertEqual(window(office, at: at(18, 9)), .init(level: .display, end: at(18, 18)))
        XCTAssertEqual(window(office, at: at(18, 17, 59)), .init(level: .display, end: at(18, 18)))
        XCTAssertNil(window(office, at: at(18, 18)))
    }

    func testAWeekdayWindowStaysShutOnTheWeekend() {
        let office = [schedule(weekdays, from: 9 * 60, to: 18 * 60)]

        XCTAssertNil(window(office, at: at(21, 10)))
        XCTAssertNil(window(office, at: at(22, 10)))
    }

    func testAnOvernightWindowBelongsToTheDayItStartsOn() {
        let fridayNight = [schedule([6], from: 22 * 60, to: 6 * 60)]

        XCTAssertNil(window(fridayNight, at: at(20, 21)))
        XCTAssertEqual(window(fridayNight, at: at(20, 23)), .init(level: .display, end: at(21, 6)))
        XCTAssertEqual(window(fridayNight, at: at(21, 2)), .init(level: .display, end: at(21, 6)))
        XCTAssertNil(window(fridayNight, at: at(21, 7)))
        XCTAssertNil(window(fridayNight, at: at(22, 2)))
    }

    func testEqualStartAndEndMeansTwentyFourHours() {
        let monday = [schedule([2], from: 8 * 60, to: 8 * 60)]

        XCTAssertEqual(window(monday, at: at(16, 8)), .init(level: .display, end: at(17, 8)))
        XCTAssertEqual(window(monday, at: at(17, 7, 59)), .init(level: .display, end: at(17, 8)))
        XCTAssertNil(window(monday, at: at(17, 8)))
    }

    func testTheStrongestOpenWindowWinsAndReportsItsOwnEnd() {
        let rules = [
            schedule(everyDay, from: 0, to: 0, level: .system),
            schedule(weekdays, from: 9 * 60, to: 18 * 60, level: .display)
        ]

        XCTAssertEqual(window(rules, at: at(18, 10)), .init(level: .display, end: at(18, 18)))
        XCTAssertEqual(window(rules, at: at(18, 19)), .init(level: .system, end: at(19, 0)))
    }

    func testADisabledScheduleNeverOpens() {
        let off = [schedule(weekdays, from: 9 * 60, to: 18 * 60, isEnabled: false)]

        XCTAssertNil(window(off, at: at(18, 10)))
        XCTAssertNil(SchedulePolicy.nextStart(schedules: off, after: at(18, 8), calendar: calendar))
    }

    func testNextStartIsLaterTodayOrTheNextMatchingDay() {
        let office = [schedule(weekdays, from: 9 * 60, to: 18 * 60)]

        XCTAssertEqual(SchedulePolicy.nextStart(schedules: office, after: at(18, 8), calendar: calendar), at(18, 9))
        XCTAssertEqual(SchedulePolicy.nextStart(schedules: office, after: at(18, 9), calendar: calendar), at(19, 9))
        XCTAssertEqual(SchedulePolicy.nextStart(schedules: office, after: at(20, 19), calendar: calendar), at(23, 9))
    }

    func testAWindowKeepsItsClockEdgesAcrossADaylightSavingShift() {
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let sunday = [schedule([1], from: 1 * 60, to: 17 * 60)]

        // 8 March 2026: clocks jump from 02:00 to 03:00 inside this window.
        XCTAssertEqual(window(sunday, at: at(8, 1, month: 3)), .init(level: .display, end: at(8, 17, month: 3)))
        XCTAssertEqual(window(sunday, at: at(8, 16, 59, month: 3)), .init(level: .display, end: at(8, 17, month: 3)))
        XCTAssertNil(window(sunday, at: at(8, 17, month: 3)))
    }

    func testStoredSchedulesSurviveARoundTripAndGarbageDecodesToNone() {
        let stored = [schedule([6], from: 22 * 60, to: 6 * 60, level: .system)]

        XCTAssertEqual(KeepAwakeSchedule.decodeList(from: KeepAwakeSchedule.encodeList(stored)), stored)
        XCTAssertEqual(KeepAwakeSchedule.decodeList(from: Data("not json".utf8)), [])
        XCTAssertEqual(KeepAwakeSchedule.decodeList(from: nil), [])
    }

    func testOutOfRangeStoredFieldsAreClamped() throws {
        let json = #"[{"id":"7F0C3E0A-3D0B-4E55-9C59-0B8F1C6B1D11","isEnabled":true,"weekdays":[0,2,9],"startMinute":-5,"endMinute":5000,"level":"display"}]"#

        let decoded = try XCTUnwrap(KeepAwakeSchedule.decodeList(from: Data(json.utf8)).first)

        XCTAssertEqual(decoded.weekdays, [2])
        XCTAssertEqual(decoded.startMinute, 0)
        XCTAssertEqual(decoded.endMinute, 1439)
    }
}
