import AppKit
import CoreGraphics

/// Owns the system-wide `CGEventTap` that swallows keyboard and scroll input
/// while Medusa is locked.
///
/// Design notes (from the input-interception + unlock research):
/// - An *active* session-level tap (`kCGSessionEventTap`, head-insert) that
///   returns `nil` drops events for the whole system. No root required.
/// - The tap can be auto-disabled by the OS (`tapDisabledByTimeout` /
///   `...ByUserInput`); we re-enable it in-callback and via a watchdog.
/// - **Mouse events always pass through, never swallowed.** The full-screen
///   shield sits under the cursor and absorbs the click, so nothing behind the
///   lock is touched — but the cursor stays alive and every macOS-reserved
///   escape (the Touch ID / password dialog, Force Quit, Notification Center)
///   stays clickable. This is the Lockpaw pattern; swallowing the mouse is what
///   turns a canceled unlock into a machine you have to power-cycle.
/// - Keyboard/scroll stay swallowed for the whole lock. The system auth dialog
///   still receives typed passwords via macOS Secure Event Input, which routes
///   keystrokes around every event tap (Apple TN2150).
/// - **Click or Enter always cues unlock.** Every intentional click / keyDown
///   (including Return / keypad Enter) hops to main and asks the controller to
///   present Touch ID. The controller is idempotent while a dialog is already
///   up; we only coalesce cues within a single run-loop turn so a key-repeat
///   storm doesn't enqueue hundreds of identical hops.
/// - If the tap can't be created (missing permission), the caller must fail
///   open — never trap the user behind a shield that isn't actually blocking.
final class InputTap {
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var watchdog: Timer?
    /// Coalesces multi-event bursts (key repeat, click+keydown same turn) into
    /// one main-queue hop. Cleared when that hop runs — never latched across
    /// cancel / fail the way the old `hasCuedAuth` was (that latch is what made
    /// a second Enter a silent no-op after a stuck first cue).
    private var cueScheduled = false

    /// Fired on the main thread when the user clicks or presses a key while
    /// locked — the cue to present Touch ID / password.
    var onInteraction: (() -> Void)?

    private(set) var isActive = false

    /// Attempts to install and enable the tap. Returns false if the OS refuses
    /// (typically missing Accessibility / Input Monitoring consent).
    func start() -> Bool {
        guard tap == nil else { return true }

        // Keyboard + scroll are swallowed; mouse buttons are observed only so a
        // click can cue authentication — they are passed straight through in the
        // callback. Mouse *movement* isn't in the mask at all, so the cursor
        // moves freely under the shield.
        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue) |
            (1 << CGEventType.scrollWheel.rawValue) |
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.leftMouseUp.rawValue) |
            (1 << CGEventType.rightMouseDown.rawValue) |
            (1 << CGEventType.rightMouseUp.rawValue) |
            (1 << CGEventType.otherMouseDown.rawValue) |
            (1 << CGEventType.otherMouseUp.rawValue)

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: inputTapCallback,
            userInfo: refcon
        ) else {
            return false
        }

        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        cueScheduled = false
        isActive = true
        startWatchdog()
        return true
    }

    func stop() {
        watchdog?.invalidate()
        watchdog = nil
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        runLoopSource = nil
        tap = nil
        isActive = false
        cueScheduled = false
    }

    /// Clears any in-flight cue coalesce. Kept for call sites that historically
    /// "re-armed" after cancel; with per-turn coalescing the next click/Enter
    /// already cues without this, but calling it is always safe.
    func rearm() {
        cueScheduled = false
    }

    /// Re-enable the tap if the OS disabled it (sleep/wake, timeout, TCC
    /// re-eval). No-op when the tap isn't installed. The 1 s watchdog already
    /// covers the steady state; this is the explicit path for session re-arm.
    func ensureEnabled() {
        guard let tap else { return }
        if !CGEvent.tapIsEnabled(tap: tap) {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        default:
            break
        }

        // Click, Enter/Return, or any other keyDown → ask the controller to
        // present Touch ID. Coalesce only within this run-loop turn; after the
        // hop runs, the next intentional action cues again. The controller
        // no-ops while a dialog is already in flight.
        if isCue(type, event: event) {
            scheduleCue()
        }

        // Mouse events ALWAYS pass through (see the type doc): the shield
        // absorbs them, and the auth dialog / Force Quit stay reachable.
        if isMouse(type) {
            return Unmanaged.passUnretained(event)
        }

        // Keyboard and scroll: swallowed for the whole lock. Password typing in
        // the system dialog bypasses the tap via Secure Event Input regardless.
        return nil
    }

    private func scheduleCue() {
        guard !cueScheduled else { return }
        cueScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.cueScheduled = false
            self.onInteraction?()
        }
    }

    /// Intentional unlock cues: any keyDown (Enter/Return included — keycodes 36
    /// and 76 are just keyDowns like the rest) or mouse button down. keyUp /
    /// flags / scroll never summon the dialog.
    private func isCue(_ type: CGEventType, event: CGEvent) -> Bool {
        switch type {
        case .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown:
            return true
        default:
            return false
        }
    }

    private func isMouse(_ type: CGEventType) -> Bool {
        switch type {
        case .leftMouseDown, .leftMouseUp,
             .rightMouseDown, .rightMouseUp,
             .otherMouseDown, .otherMouseUp:
            return true
        default:
            return false
        }
    }

    private func startWatchdog() {
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self, let tap = self.tap else { return }
            if !CGEvent.tapIsEnabled(tap: tap) {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        watchdog = timer
    }
}

/// C-compatible trampoline: recovers the `InputTap` instance from the refcon
/// and forwards to its handler. Runs on the main run loop.
private func inputTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let tap = Unmanaged<InputTap>.fromOpaque(refcon).takeUnretainedValue()
    return tap.handle(type: type, event: event)
}
