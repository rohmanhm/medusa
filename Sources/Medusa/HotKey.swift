import AppKit

/// Global hotkey (default ⌘⇧L, configurable in Settings) that triggers a lock
/// from anywhere.
///
/// Implemented with an `NSEvent` global monitor rather than Carbon: Medusa
/// already requires Accessibility consent (which the monitor needs), and this
/// keeps the code dependency-free. The monitor observes without consuming —
/// fine here, since lock chords aren't common system shortcuts and we only act
/// when unlocked. The shortcut is read from `AppSettings` per event (a cached
/// in-memory lookup), so changes apply instantly with no re-registration.
final class HotKey {
    private var globalMonitor: Any?
    private var localMonitor: Any?

    var onTrigger: (() -> Void)?

    func start() {
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.evaluate(event)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.evaluate(event)
            return event
        }
    }

    func stop() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
    }

    private func evaluate(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == AppSettings.hotKeyModifiers && event.keyCode == AppSettings.hotKeyKeyCode {
            onTrigger?()
        }
    }
}
