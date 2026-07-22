import Foundation
import IOKit.pwr_mgt

/// Holds an IOKit power assertion so the Mac stays awake and the display stays
/// on while locked — long-running builds, renders, and agents keep running
/// underneath the shield.
///
/// `PreventUserIdleDisplaySleep` (equivalent to `caffeinate -d`) also blocks
/// idle *system* sleep, which is what we want: the machine must not doze off
/// while the user is away and the screen is locked.
final class PowerAssertion {
    private var id: IOPMAssertionID = 0
    private(set) var held = false

    /// Acquire the keep-awake assertion. Returns `true` when it is held after
    /// the call (already held counts as success). A `false` return means the
    /// kernel refused — callers that care about a lit display must surface that
    /// instead of assuming the screen will stay on.
    @discardableResult
    func begin() -> Bool {
        guard !held else { return true }
        var assertionID: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "Medusa is locking input" as CFString,
            &assertionID
        )
        if result == kIOReturnSuccess {
            id = assertionID
            held = true
        }
        return held
    }

    /// Drop and re-create the assertion. Sleep/wake and session switches can
    /// leave us thinking we still hold one when the kernel has already cleared
    /// it — reaffirming is cheaper than debugging a display that quietly went
    /// dark an hour into a lock.
    @discardableResult
    func reaffirm() -> Bool {
        end()
        return begin()
    }

    func end() {
        guard held else { return }
        IOPMAssertionRelease(id)
        held = false
        id = 0
    }
}
