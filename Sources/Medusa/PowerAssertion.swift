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

    func begin() {
        guard !held else { return }
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
    }

    func end() {
        guard held else { return }
        IOPMAssertionRelease(id)
        held = false
        id = 0
    }
}
