import XCTest
@testable import Medusa

/// November 2026: the 18th is a Wednesday, the 20th a Friday.
final class ScheduleCopyTests: XCTestCase {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US")
        calendar.timeZone = TimeZone(identifier: "Asia/Jakarta")!
        return calendar
    }()

    private func at(_ day: Int, _ hour: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour))!
    }

    /// 24-hour "HH:mm" in the test calendar, so expectations don't depend on
    /// the locale of the Mac running the tests.
    private func clockTime(_ date: Date) -> String {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", parts.hour!, parts.minute!)
    }

    private let office = KeepAwakeSchedule(weekdays: [2, 3, 4, 5, 6], startMinute: 9 * 60, endMinute: 18 * 60)

    func testDaysReadAsTheGroupsPeopleSay() {
        XCTAssertEqual(ScheduleCopy.days([2, 3, 4, 5, 6], calendar: calendar), "Weekdays")
        XCTAssertEqual(ScheduleCopy.days([1, 7], calendar: calendar), "Weekends")
        XCTAssertEqual(ScheduleCopy.days([1, 2, 3, 4, 5, 6, 7], calendar: calendar), "Every day")
        XCTAssertEqual(ScheduleCopy.days([6, 2, 4], calendar: calendar), "Mon, Wed, Fri")
        XCTAssertEqual(ScheduleCopy.days([], calendar: calendar), "No days")
    }

    func testOddDaysFollowTheCalendarsFirstWeekday() {
        var mondayFirst = calendar
        mondayFirst.firstWeekday = 2

        XCTAssertEqual(ScheduleCopy.days([1, 2], calendar: calendar), "Sun, Mon")
        XCTAssertEqual(ScheduleCopy.days([1, 2], calendar: mondayFirst), "Mon, Sun")
    }

    func testSummaryNamesTheDaysAndTheHours() {
        XCTAssertEqual(
            ScheduleCopy.summary(office, calendar: calendar, clockTime: clockTime),
            "Weekdays, 09:00 – 18:00"
        )
    }

    func testStatusSaysWhenTheOpenScheduleEnds() {
        XCTAssertEqual(
            ScheduleCopy.status(schedules: [office], at: at(18, 10), calendar: calendar, clockTime: clockTime),
            "Inside a Schedule until 18:00"
        )
    }

    func testStatusSaysWhenTheNextScheduleStarts() {
        func status(_ day: Int, _ hour: Int) -> String {
            ScheduleCopy.status(schedules: [office], at: at(day, hour), calendar: calendar, clockTime: clockTime)
        }

        XCTAssertEqual(status(18, 8), "Next starts today at 09:00")
        XCTAssertEqual(status(18, 19), "Next starts tomorrow at 09:00")
        XCTAssertEqual(status(20, 19), "Next starts Monday at 09:00")
    }

    func testStatusWithNothingToWaitFor() {
        var off = office
        off.isEnabled = false

        XCTAssertEqual(ScheduleCopy.status(schedules: [], at: at(18, 10), calendar: calendar), "No Schedules yet")
        XCTAssertEqual(ScheduleCopy.status(schedules: [off], at: at(18, 10), calendar: calendar), "No Schedule is on")
    }
}
