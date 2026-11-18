import AppKit
import XCTest
@testable import Medusa

final class ShieldControllerTests: XCTestCase {
    private let authLevel = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)))
    private let lockedLevel = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))

    /// Far outside every display, so the overlays under test never show.
    private var layout = [NSRect(x: -30_000, y: -30_000, width: 40, height: 30)]

    override func setUp() {
        NSApplication.shared.setActivationPolicy(.prohibited)
    }

    private func spin(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    func testOverlaysRebuiltDuringAuthStayBelowTheAuthDialog() {
        let shield = ShieldController(frames: { [unowned self] in self.layout })
        shield.show()
        XCTAssertEqual(shield.windowLevels, [lockedLevel])
        shield.setAuthMode(true)
        XCTAssertEqual(shield.windowLevels, [authLevel])

        layout = [NSRect(x: -30_000, y: -30_000, width: 50, height: 30)]
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        spin(ShieldRebuild.coalesceDelay + 0.25)

        XCTAssertEqual(shield.windowLevels, [authLevel])
        shield.hide()
    }

    func testOverlaysAddedForANewDisplayDuringAuthStayBelowTheAuthDialog() {
        let shield = ShieldController(frames: { [unowned self] in self.layout })
        shield.show()
        shield.setAuthMode(true)

        layout.append(NSRect(x: -31_000, y: -30_000, width: 40, height: 30))
        shield.reaffirm()

        XCTAssertEqual(shield.windowLevels, [authLevel, authLevel])
        shield.hide()
    }

    func testEndingAuthRaisesEveryOverlayBackToFullShielding() {
        let shield = ShieldController(frames: { [unowned self] in self.layout })
        shield.show()
        shield.setAuthMode(true)
        shield.setAuthMode(false)

        XCTAssertEqual(shield.windowLevels, [lockedLevel])
        shield.hide()
    }

    func testANewLockStartsAtFullShieldingAfterAnAuthThatNeverEnded() {
        let shield = ShieldController(frames: { [unowned self] in self.layout })
        shield.show()
        shield.setAuthMode(true)
        shield.hide()

        shield.show()

        XCTAssertEqual(shield.windowLevels, [lockedLevel])
        shield.hide()
    }
}
