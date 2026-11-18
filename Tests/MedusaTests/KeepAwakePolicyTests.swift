import XCTest
@testable import Medusa

final class KeepAwakePolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var inAnHour: Date { now.addingTimeInterval(3600) }
    private var inTwoHours: Date { now.addingTimeInterval(7200) }

    // MARK: When the engine next looks at the clock

    func testALiveHoldIsCheckedEverySecond() {
        let plan = KeepAwakePolicy.tickPlan(holding: true, schedule: .idle, nextScheduleStart: inAnHour, now: now)

        XCTAssertEqual(plan, .everySecond)
    }

    func testAnIdleEngineSleepsUntilTheNextWindowOpens() {
        let plan = KeepAwakePolicy.tickPlan(holding: false, schedule: .idle, nextScheduleStart: inAnHour, now: now)

        XCTAssertEqual(plan, .at(inAnHour))
    }

    func testAnIdleEngineWithNoSchedulesDoesNotTickAtAll() {
        let plan = KeepAwakePolicy.tickPlan(holding: false, schedule: .idle, nextScheduleStart: nil, now: now)

        XCTAssertEqual(plan, .idle)
    }

    func testAPausedScheduleIsLookedAtAgainWhenThePauseRunsOut() {
        let plan = KeepAwakePolicy.tickPlan(
            holding: false,
            schedule: .paused(until: inAnHour),
            nextScheduleStart: inTwoHours,
            now: now
        )

        XCTAssertEqual(plan, .at(inAnHour))
    }

    func testAScheduleHeldOffByTheBatteryGuardIsRecheckedInAMinute() {
        let plan = KeepAwakePolicy.tickPlan(holding: false, schedule: .batteryLow, nextScheduleStart: inAnHour, now: now)

        XCTAssertEqual(plan, .at(now.addingTimeInterval(60)))
    }

    // MARK: What bounds the kernel timeout

    func testAFiniteSessionAloneBoundsTheAssertionAtItsDeadline() {
        let session = KeepAwakeSession(deadline: inAnHour, level: .display, endsAtClockTime: false)

        XCTAssertEqual(KeepAwakePolicy.kernelBound(session: session, lockHold: false, schedule: .idle), inAnHour)
    }

    func testTheLatestEndWinsWhenASessionAndAScheduleBothHold() {
        let session = KeepAwakeSession(deadline: inAnHour, level: .display, endsAtClockTime: false)
        let window = SchedulePolicy.Window(level: .system, end: inTwoHours)

        XCTAssertEqual(
            KeepAwakePolicy.kernelBound(session: session, lockHold: false, schedule: .holding(window)),
            inTwoHours
        )
    }

    func testAnOpenEndedHoldLeavesTheAssertionUnbounded() {
        let finite = KeepAwakeSession(deadline: inAnHour, level: .display, endsAtClockTime: false)
        let indefinite = KeepAwakeSession(deadline: nil, level: .display, endsAtClockTime: false)
        let window = SchedulePolicy.Window(level: .system, end: inTwoHours)

        XCTAssertNil(KeepAwakePolicy.kernelBound(session: finite, lockHold: true, schedule: .idle))
        XCTAssertNil(KeepAwakePolicy.kernelBound(session: indefinite, lockHold: false, schedule: .holding(window)))
    }

    // MARK: Menu copy

    func testTheHeaderLeadsWithTheSessionAndListsTheOtherHolds() {
        let session = KeepAwakeSession(deadline: now.addingTimeInterval(83 * 60), level: .display, endsAtClockTime: false)
        let window = SchedulePolicy.Window(level: .system, end: inTwoHours)

        let header = KeepAwakePolicy.headerText(session: session, schedule: .holding(window), lockHold: true, now: now)

        XCTAssertEqual(header, "Awake · 1 h 23 m left · also: schedule, lock")
    }

    func testAnUntilSessionShowsItsClockTime() {
        let session = KeepAwakeSession(deadline: inAnHour, level: .display, endsAtClockTime: true)

        let header = KeepAwakePolicy.headerText(
            session: session, schedule: .idle, lockHold: false, now: now, clockTime: { _ in "5:00 PM" }
        )

        XCTAssertEqual(header, "Awake · until 5:00 PM")
    }

    func testNothingHeldMeansNoHeader() {
        XCTAssertNil(KeepAwakePolicy.headerText(session: nil, schedule: .paused(until: inAnHour), lockHold: false, now: now))
    }

    func testAScheduleThatIsNotHoldingExplainsItself() {
        XCTAssertEqual(
            KeepAwakePolicy.scheduleNote(.paused(until: inAnHour), clockTime: { _ in "6:00 PM" }),
            "Schedule paused until 6:00 PM"
        )
        XCTAssertEqual(KeepAwakePolicy.scheduleNote(.batteryLow), "Schedule waiting · battery low")
        XCTAssertNil(KeepAwakePolicy.scheduleNote(.idle))
    }
}
