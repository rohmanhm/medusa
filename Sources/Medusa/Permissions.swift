import AppKit
import ApplicationServices
import IOKit.hid

/// TCC permission checks and deep-links. An active, event-swallowing tap needs
/// *both* grants:
/// - **Accessibility** — to post/alter/swallow events.
/// - **Input Monitoring** — to observe the event stream.
///
/// There is no first-class "is my tap allowed" API; the ground truth is whether
/// `CGEvent.tapCreate` succeeds (handled in `InputTap`). These checks drive the
/// onboarding UI only.
enum Permissions {
    static func hasAccessibility() -> Bool {
        AXIsProcessTrusted()
    }

    static func hasInputMonitoring() -> Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }

    static var allGranted: Bool {
        hasAccessibility() && hasInputMonitoring()
    }

    /// Triggers the system Accessibility consent prompt (adds Medusa to the list
    /// with a toggle, and shows the "open System Settings" alert).
    static func promptAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// Triggers the system Input Monitoring consent prompt.
    static func promptInputMonitoring() {
        _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }

    static func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    static func openInputMonitoringSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
    }

    private static func open(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}
