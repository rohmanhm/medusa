import AppKit
import LocalAuthentication
import XCTest
@testable import Medusa

final class FakeInputBlocker: InputBlocker {
    var onInteraction: (() -> Void)?
    private(set) var isActive = false
    var startSucceeds = true

    func start() -> Bool {
        isActive = startSucceeds
        return startSucceeds
    }

    func stop() { isActive = false }
    func rearm() {}
    func ensureEnabled() {}

    func cue() { onInteraction?() }
}

/// Stands in for the system Touch ID / password dialog.
final class FakeAuthDialog {
    private(set) var presented = 0
    private(set) var cancelled = 0
    private var reply: ((Bool, Error?) -> Void)?

    var isUp: Bool { reply != nil }

    func evaluate(reason: String, reply: @escaping (Bool, Error?) -> Void) -> () -> Void {
        presented += 1
        self.reply = reply
        return { [unowned self] in
            cancelled += 1
            answer(success: false, error: .appCancel)
        }
    }

    func answer(success: Bool, error: LAError.Code? = nil) {
        let reply = self.reply
        self.reply = nil
        reply?(success, error.map { LAError($0) })
    }
}

final class LockControllerTests: XCTestCase {
    private let authLevel = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)))
    private let lockedLevel = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))

    private var tap: FakeInputBlocker!
    private var dialog: FakeAuthDialog!
    private var shield: ShieldController!
    private var lock: LockController!

    override func setUp() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        tap = FakeInputBlocker()
        dialog = FakeAuthDialog()
        shield = ShieldController(frames: { [NSRect(x: -30_000, y: -30_000, width: 40, height: 30)] })
        lock = LockController(
            tap: tap,
            shield: shield,
            auth: Authenticator(evaluate: dialog.evaluate),
            permissionsGranted: { true }
        )
    }

    override func tearDown() {
        dialog.answer(success: true)
        spin()
        shield.hide()
    }

    /// Lets the auth reply hop to the main queue, and timers fire.
    private func spin(_ seconds: TimeInterval = 0.05) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    func testWakeEventsLeaveAFreshAuthDialogUp() {
        lock.lock()
        tap.cue()
        XCTAssertEqual(dialog.presented, 1)

        for event in [LockPolicy.SessionEvent.screensDidWake, .didWake, .sessionDidBecomeActive] {
            lock.handleSessionEvent(event)
            spin()

            XCTAssertEqual(dialog.cancelled, 0, "\(event)")
            XCTAssertTrue(dialog.isUp, "\(event)")
            XCTAssertEqual(shield.windowLevels, [authLevel], "\(event)")
        }
    }

    func testCancelKeepsTheLockAndTheNextCueBringsTheDialogBack() {
        lock.lock()
        tap.cue()

        dialog.answer(success: false, error: .userCancel)
        spin()

        XCTAssertTrue(lock.isLocked)
        XCTAssertEqual(shield.windowLevels, [lockedLevel])
        tap.cue()
        XCTAssertEqual(dialog.presented, 2)
    }

    func testAuthenticatingUnlocks() {
        lock.lock()
        tap.cue()

        dialog.answer(success: true)
        spin()

        XCTAssertFalse(lock.isLocked)
        XCTAssertFalse(shield.isShown)
        XCTAssertFalse(tap.isActive)
    }

    func testSystemLockYieldsAndSystemUnlockReleases() {
        lock.lock()
        tap.cue()

        lock.handleSessionEvent(.systemScreenDidLock)

        XCTAssertTrue(lock.isLocked)
        XCTAssertFalse(shield.isShown)
        XCTAssertFalse(tap.isActive)
        XCTAssertEqual(dialog.cancelled, 1)

        lock.handleSessionEvent(.didWake)
        XCTAssertFalse(shield.isShown)

        lock.handleSessionEvent(.systemScreenDidUnlock)
        XCTAssertFalse(lock.isLocked)
    }

    func testTwoSystemCancelsInARowFailOpen() {
        lock.lock()
        tap.cue()

        dialog.answer(success: false, error: .systemCancel)
        spin(0.45)
        XCTAssertTrue(lock.isLocked)
        XCTAssertEqual(dialog.presented, 2)

        dialog.answer(success: false, error: .systemCancel)
        spin()
        XCTAssertFalse(lock.isLocked)
    }

    func testLockFailsOpenWhenInputCannotBeBlocked() {
        var failures = 0
        lock.onLockFailed = { failures += 1 }
        tap.startSucceeds = false

        lock.lock()

        XCTAssertFalse(lock.isLocked)
        XCTAssertFalse(shield.isShown)
        XCTAssertEqual(failures, 1)
    }
}
