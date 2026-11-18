import XCTest
@testable import Medusa

/// Wednesday 18 November 2026, in the Mac's own calendar.
final class KeepAwakeEngineTests: XCTestCase {
    private var clock = Date()
    private var schedules: [KeepAwakeSchedule] = []
    private var battery = KeepAwakeController.BatteryStatus()
    private var engine: KeepAwakeController!

    private let office = KeepAwakeSchedule(weekdays: [2, 3, 4, 5, 6], startMinute: 9 * 60, endMinute: 18 * 60, level: .display)

    private func at(_ hour: Int, _ minute: Int = 0, day: Int = 18) -> Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }

    override func setUp() {
        UserDefaults.standard.set(true, forKey: AppSettings.Keys.keepAwakeGuardEnabled)
        UserDefaults.standard.set(10, forKey: AppSettings.Keys.keepAwakeGuardThreshold)
        clock = at(10)
        schedules = []
        battery = .init()
        engine = KeepAwakeController(
            now: { [unowned self] in self.clock },
            schedules: { [unowned self] in self.schedules },
            battery: { [unowned self] in self.battery }
        )
    }

    override func tearDown() {
        engine = nil
        UserDefaults.standard.removeObject(forKey: AppSettings.Keys.keepAwakeGuardEnabled)
        UserDefaults.standard.removeObject(forKey: AppSettings.Keys.keepAwakeGuardThreshold)
    }

    /// The lines `pmset -g assertions` prints for this process.
    private func kernelAssertions() -> String {
        let pmset = Process()
        pmset.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        pmset.arguments = ["-g", "assertions"]
        let pipe = Pipe()
        pmset.standardOutput = pipe
        try? pmset.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        pmset.waitUntilExit()

        var mine: [String] = []
        var inMyBlock = false
        for line in output.split(separator: "\n") {
            if line.contains("pid ") && line.contains("(") {
                inMyBlock = line.contains("pid \(ProcessInfo.processInfo.processIdentifier)(")
            }
            if inMyBlock { mine.append(String(line)) }
        }
        return mine.joined(separator: "\n")
    }

    func testAnOpenScheduleKeepsTheMacAwakeAtItsLevel() {
        schedules = [office]
        engine.refresh()

        XCTAssertEqual(engine.scheduleStatus, .holding(.init(level: .display, end: at(18))))
        XCTAssertEqual(engine.effectiveLevel, .display)
        XCTAssertTrue(kernelAssertions().contains("PreventUserIdleDisplaySleep named: \"Medusa keep awake (display)\""))
    }

    func testTheScheduleLetsGoWhenItsWindowCloses() {
        schedules = [office]
        engine.refresh()

        clock = at(18)
        engine.refresh()

        XCTAssertEqual(engine.scheduleStatus, .idle)
        XCTAssertNil(engine.effectiveLevel)
        XCTAssertEqual(kernelAssertions(), "")
    }

    func testNoScheduleMeansNoHold() {
        engine.refresh()

        XCTAssertEqual(engine.scheduleStatus, .idle)
        XCTAssertNil(engine.effectiveLevel)
    }

    func testPausingLetsTheMacSleepUntilTheWindowEndsThenTheNextWindowOpens() {
        schedules = [office]
        engine.refresh()

        engine.pauseSchedule()
        XCTAssertEqual(engine.scheduleStatus, .paused(until: at(18)))
        XCTAssertNil(engine.effectiveLevel)

        clock = at(17, 59)
        engine.refresh()
        XCTAssertEqual(engine.scheduleStatus, .paused(until: at(18)))

        clock = at(9, day: 19)
        engine.refresh()
        XCTAssertEqual(engine.scheduleStatus, .holding(.init(level: .display, end: at(18, day: 19))))
    }

    func testResumingAPausedScheduleHoldsAgain() {
        schedules = [office]
        engine.refresh()
        engine.pauseSchedule()

        engine.resumeSchedule()

        XCTAssertEqual(engine.effectiveLevel, .display)
    }

    func testTheBatteryGuardKeepsAScheduleOffUntilPowerReturns() {
        schedules = [office]
        battery = .init(onBattery: true, percent: 8, warningFinal: false)
        engine.refresh()
        XCTAssertEqual(engine.scheduleStatus, .batteryLow)
        XCTAssertNil(engine.effectiveLevel)

        battery = .init(onBattery: false, percent: 9, warningFinal: false)
        engine.refresh()
        XCTAssertEqual(engine.effectiveLevel, .display)
    }

    func testASessionAndAScheduleComposeAndTheStrongerLevelWins() {
        schedules = [KeepAwakeSchedule(weekdays: [4], startMinute: 0, endMinute: 0, level: .system)]
        engine.refresh()
        XCTAssertEqual(engine.effectiveLevel, .system)

        engine.startSession(end: .duration(600), level: .display)
        XCTAssertEqual(engine.effectiveLevel, .display)

        engine.stopSession()
        XCTAssertEqual(engine.effectiveLevel, .system)
    }

    /// The engine's own assertions time out with TurnOff. (Display awake also
    /// declares user activity, a separate assertion that always times out
    /// with Release, so only TurnOff is the Session's bound.)
    func testAHoldThatOutlivesASessionCarriesNoKernelTimeoutFromIt() {
        engine.startSession(end: .duration(600), level: .display)
        XCTAssertTrue(kernelAssertions().contains("Action=TimeoutActionTurnOff"))

        engine.setLockHold(.display)
        clock = at(10, 11)
        engine.refresh()

        XCTAssertNil(engine.session)
        XCTAssertEqual(engine.effectiveLevel, .display)
        XCTAssertTrue(kernelAssertions().contains("Medusa keep awake (display)"))
        XCTAssertFalse(kernelAssertions().contains("Action=TimeoutActionTurnOff"))
    }

    func testTheHeaderNamesEveryLiveHold() {
        schedules = [office]
        engine.refresh()
        engine.startSession(end: .indefinitely, level: .system)
        engine.setLockHold(.display)

        XCTAssertEqual(engine.headerText(), "Awake · indefinitely · also: schedule, lock")
    }

    func testAnIdleEngineWakesItselfWhenTheNextWindowOpens() {
        clock = at(9).addingTimeInterval(-2)
        schedules = [office]
        engine.refresh()
        XCTAssertNil(engine.effectiveLevel)

        // The wall clock reaches 09:00. Nothing tells the engine: its own
        // timer, armed for the window's start (plus up to 1.5 s of slack),
        // has to notice.
        clock = at(9)
        RunLoop.main.run(until: Date().addingTimeInterval(5))

        XCTAssertEqual(engine.effectiveLevel, .display)
    }

    func testAnEngineWithNothingToWatchDoesNotTick() {
        var ticks = 0
        engine.onTick = { ticks += 1 }
        engine.refresh()

        RunLoop.main.run(until: Date().addingTimeInterval(2.5))

        XCTAssertEqual(ticks, 0)
    }

    func testAnEngineWithALiveHoldTicksEverySecond() {
        var ticks = 0
        engine.onTick = { ticks += 1 }
        engine.startSession(end: .indefinitely, level: .system)

        RunLoop.main.run(until: Date().addingTimeInterval(2.9))

        XCTAssertEqual(ticks, 2)
    }
}
