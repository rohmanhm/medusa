import AppKit
import ApplicationServices
import Combine
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

/// The two grants as the Permissions pane shows them.
///
/// Polling exists for one moment: the user is in System Settings flipping a
/// toggle and the pane should notice. So it polls only while a grant is
/// missing, and stops for good once both are in. The pane used to poll TCC
/// every second for the life of the process, Settings window closed or not.
final class PermissionsStatus: ObservableObject {
    struct Grants: Equatable {
        var accessibility: Bool
        var inputMonitoring: Bool

        var all: Bool { accessibility && inputMonitoring }
    }

    @Published private(set) var grants: Grants

    private let read: () -> Grants
    private let interval: TimeInterval
    private var timer: Timer?

    init(
        interval: TimeInterval = 1,
        read: @escaping () -> Grants = {
            Grants(
                accessibility: Permissions.hasAccessibility(),
                inputMonitoring: Permissions.hasInputMonitoring()
            )
        }
    ) {
        self.interval = interval
        self.read = read
        grants = read()
    }

    deinit {
        timer?.invalidate()
    }

    /// Re-read now, then keep watching until both grants are in.
    func start() {
        refresh()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func refresh() {
        let next = read()
        if next != grants { grants = next }
        if next.all {
            stop()
        } else if timer == nil {
            let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.refresh() }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
    }
}
