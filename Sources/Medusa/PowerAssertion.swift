import Foundation
import IOKit.pwr_mgt

/// Holds IOKit power assertions so the Mac stays awake — long-running builds,
/// renders, and agents keep running while the user is away.
///
/// Level-aware (see `AwakeLevel`): Display awake holds
/// `PreventUserIdleDisplaySleep` **plus** `PreventUserIdleSystemSleep`
/// alongside (self-documenting in `pmset -g assertions`, Amphetamine
/// precedent); System awake holds the latter alone. `PreventSystemSleep` is
/// deprecated and never used.
///
/// Assertions that carry a finite deadline are created with a kernel timeout
/// (`TimeoutSeconds` + `TimeoutActionTurnOff`) so a hung Medusa is disarmed
/// by the kernel; Extend re-arms the same ID. Indefinite holds carry no
/// timeout (infinity can't be bounded) — the engine's absolute deadline is
/// the authority and `held` is tracked from live IDs, never from the
/// assertion object's post-timeout level (which still reports On).
final class PowerAssertion {
    private var displayID: IOPMAssertionID = 0
    private var systemID: IOPMAssertionID = 0
    private(set) var level: AwakeLevel?
    private var timeoutSeconds: TimeInterval = 0

    private(set) var held = false

    /// Acquire the keep-awake assertion at the given level. Already held at
    /// the same level counts as success (and re-arms the timeout when one is
    /// given). Returns whether anything is held after the call.
    @discardableResult
    func begin(level: AwakeLevel = .display, timeoutSeconds: TimeInterval = 0) -> Bool {
        if held, self.level == level {
            if timeoutSeconds > 0 { retimeout(timeoutSeconds) }
            return held
        }
        if held { end() }
        let timeout = max(0, timeoutSeconds)
        switch level {
        case .display:
            if let id = create(
                type: kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                name: "Medusa keep awake (display)",
                timeout: timeout
            ) {
                displayID = id
            }
            if let id = create(
                type: kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                name: "Medusa keep awake (system)",
                timeout: timeout
            ) {
                systemID = id
            }
        case .system:
            if let id = create(
                type: kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                name: "Medusa keep awake (system)",
                timeout: timeout
            ) {
                systemID = id
            }
        }
        // Partial success still counts as held (either assertion alone keeps
        // the Mac from idle sleep at our levels). Full failure returns false
        // so the caller can surface the broken promise once.
        self.level = (displayID != 0 || systemID != 0) ? level : nil
        held = displayID != 0 || systemID != 0
        self.timeoutSeconds = timeout
        return held
    }

    /// Drop and re-create at the same level/timeout. Sleep/wake and session
    /// switches can leave us thinking we still hold one when the kernel has
    /// already cleared it — reaffirming is cheaper than debugging a display
    /// that quietly went dark an hour into a Session.
    @discardableResult
    func reaffirm() -> Bool {
        let current = level ?? .display
        let timeout = timeoutSeconds
        end()
        return begin(level: current, timeoutSeconds: timeout)
    }

    /// Extend the kernel timeout on the same IDs (no teardown). Returns false
    /// when nothing is held.
    @discardableResult
    func retimeout(_ seconds: TimeInterval) -> Bool {
        guard held else { return false }
        let timeout = max(0, seconds)
        timeoutSeconds = timeout
        guard timeout > 0 else { return true }
        var ok = true
        if displayID != 0 {
            ok = setTimeout(timeout, on: displayID) && ok
        }
        if systemID != 0 {
            ok = setTimeout(timeout, on: systemID) && ok
        }
        return ok
    }

    func end() {
        guard held else { return }
        if displayID != 0 { IOPMAssertionRelease(displayID) }
        if systemID != 0 { IOPMAssertionRelease(systemID) }
        displayID = 0
        systemID = 0
        level = nil
        timeoutSeconds = 0
        held = false
    }

    private func create(type: CFString, name: String, timeout: TimeInterval) -> IOPMAssertionID? {
        var assertionID: IOPMAssertionID = 0
        let result: IOReturn
        if timeout > 0 {
            let properties: CFDictionary = [
                kIOPMAssertionTypeKey as String: type,
                kIOPMAssertionNameKey as String: name as CFString,
                kIOPMAssertionLevelKey as String: NSNumber(value: kIOPMAssertionLevelOn),
                kIOPMAssertionTimeoutKey as String: NSNumber(value: Int(timeout)),
                kIOPMAssertionTimeoutActionKey as String: kIOPMAssertionTimeoutActionTurnOff as CFString
            ] as CFDictionary
            result = IOPMAssertionCreateWithProperties(properties, &assertionID)
        } else {
            result = IOPMAssertionCreateWithName(
                type,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                name as CFString,
                &assertionID
            )
        }
        guard result == kIOReturnSuccess, assertionID != 0 else { return nil }
        return assertionID
    }

    private func setTimeout(_ seconds: TimeInterval, on id: IOPMAssertionID) -> Bool {
        IOPMAssertionSetProperty(
            id,
            kIOPMAssertionTimeoutKey as CFString,
            NSNumber(value: Int(seconds))
        ) == kIOReturnSuccess
    }
}
