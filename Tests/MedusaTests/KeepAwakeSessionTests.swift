import XCTest
@testable import Medusa

final class KeepAwakeSessionTests: XCTestCase {
    private let calendar = Calendar.current

    private func date(day: Int, hour: Int, minute: Int) throws -> Date {
        try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute)))
    }

    func testExtendingAnIndefiniteSessionKeepsItIndefinite() {
        let engine = KeepAwakeController()
        engine.startSession(end: .indefinitely, level: .system)
        engine.extend(minutes: 15)
        XCTAssertNotNil(engine.session)
        XCTAssertNil(engine.session?.deadline)
        engine.stopSession()
    }

    func testExtendingAFiniteSessionPushesItsDeadline() throws {
        let engine = KeepAwakeController()
        engine.startSession(end: .duration(600), level: .system)
        let before = try XCTUnwrap(engine.session?.deadline)
        engine.extend(minutes: 15)
        let after = try XCTUnwrap(engine.session?.deadline)
        XCTAssertEqual(after.timeIntervalSince(before), 900, accuracy: 0.001)
        engine.stopSession()
    }

    func testUntilPickedLateAtNightEndsTheSameNight() throws {
        let halfPastEleven = try date(day: 18, hour: 23, minute: 30)
        let pickerValue = try date(day: 19, hour: 23, minute: 45)

        let deadline = KeepAwakeEndCondition.until(pickerValue).deadline(from: halfPastEleven)

        XCTAssertEqual(deadline, try date(day: 18, hour: 23, minute: 45))
    }

    func testUntilPickedEarlierThanNowMeansTomorrow() throws {
        let afternoon = try date(day: 18, hour: 15, minute: 0)
        let pickerValue = try date(day: 18, hour: 9, minute: 0)

        let deadline = KeepAwakeEndCondition.until(pickerValue).deadline(from: afternoon)

        XCTAssertEqual(deadline, try date(day: 19, hour: 9, minute: 0))
    }

    func testBarCountdownShowsTheTimeLeftOfAFiniteSession() throws {
        let now = try date(day: 18, hour: 9, minute: 0)

        let text = KeepAwakePolicy.barCountdown(enabled: true, deadline: now.addingTimeInterval(3723), now: now)

        XCTAssertEqual(text, "1:02:03")
    }

    func testBarCountdownIsEmptyWhenTurnedOffOrIndefinite() throws {
        let now = try date(day: 18, hour: 9, minute: 0)

        XCTAssertNil(KeepAwakePolicy.barCountdown(enabled: false, deadline: now.addingTimeInterval(60), now: now))
        XCTAssertNil(KeepAwakePolicy.barCountdown(enabled: true, deadline: nil, now: now))
    }
}
