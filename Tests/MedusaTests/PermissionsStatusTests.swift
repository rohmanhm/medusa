import XCTest
@testable import Medusa

final class PermissionsStatusTests: XCTestCase {
    private func spin(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    func testDoesNotPollOnceBothGrantsAreIn() {
        var reads = 0
        let status = PermissionsStatus(interval: 0.05) {
            reads += 1
            return .init(accessibility: true, inputMonitoring: true)
        }
        status.start()
        let readsAfterStart = reads

        spin(0.4)

        XCTAssertEqual(readsAfterStart, 2)
        XCTAssertEqual(reads, 2)
    }

    func testPollsWhileAGrantIsMissingAndStopsWhenItArrives() {
        var reads = 0
        let status = PermissionsStatus(interval: 0.05) {
            reads += 1
            return .init(accessibility: true, inputMonitoring: reads >= 4)
        }
        status.start()
        XCTAssertEqual(status.grants, .init(accessibility: true, inputMonitoring: false))

        spin(0.5)

        XCTAssertEqual(status.grants, .init(accessibility: true, inputMonitoring: true))
        XCTAssertEqual(reads, 4)
    }

    func testStopEndsThePollWhileAGrantIsStillMissing() {
        var reads = 0
        let status = PermissionsStatus(interval: 0.05) {
            reads += 1
            return .init(accessibility: false, inputMonitoring: false)
        }
        status.start()
        spin(0.2)
        XCTAssertGreaterThanOrEqual(reads, 4)

        status.stop()
        let readsAtStop = reads
        spin(0.3)

        XCTAssertEqual(reads, readsAtStop)
    }
}
