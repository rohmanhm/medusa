import Foundation
import UserNotifications

/// Keep Awake notifications: "Keep Awake ended" (un-chosen ends only) and the
/// opt-in "Ending in …" nudge with an Extend action.
///
/// Hard invariant: nothing here touches `UNUserNotificationCenter` without a
/// bundle identifier. `current()` traps uncatchably when unbundled (`swift
/// run`, every `--self-test` / `--lock-test` / `--snapshot-*` / probe entry
/// point) — so every entry checks `available` first and every unbundled path
/// stays notification-free. The menu's Extend path is the guaranteed path
/// (banner-vs-alert is the user's setting).
enum KeepAwakeNotifier {
    static let categoryID = "medusa.keepawake"
    static let extendActionID = "medusa.keepawake.extend30"

    static var available: Bool { Bundle.main.bundleIdentifier != nil }

    /// Delegate + categories register at launch; authorization is deferred to
    /// the first Session start. No provisional authorization (provisional
    /// lands silently in history — an Extend prompt nobody sees).
    static func registerCategories(delegate: UNUserNotificationCenterDelegate) {
        guard available else { return }
        let extend = UNNotificationAction(
            identifier: extendActionID,
            title: "Extend 30 min",
            options: []
        )
        let category = UNNotificationCategory(
            identifier: categoryID,
            actions: [extend],
            intentIdentifiers: [],
            options: []
        )
        let center = UNUserNotificationCenter.current()
        center.delegate = delegate
        center.setNotificationCategories([category])
    }

    static func requestAuthorizationIfNeeded() {
        guard available else { return }
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        }
    }

    static func postEnded(reason: KeepAwakeEndReason) {
        guard available, AppSettings.keepAwakeEndedNotify else { return }
        let reasonCopy: String
        switch reason {
        case .elapsed:
            reasonCopy = "The Session duration elapsed."
        case .timePassed:
            reasonCopy = "The end time passed."
        case .battery:
            reasonCopy = "The battery ran low."
        }
        post(
            title: "Keep Awake ended",
            body: reasonCopy + " Your Mac will sleep on its normal schedule.",
            withExtend: false
        )
    }

    static func postEndingSoon(deadline: Date) {
        guard available else { return }
        let remaining = max(1, Int(deadline.timeIntervalSince(Date()).rounded(.up) / 60))
        post(
            title: "Keep Awake ending soon",
            body: "About \(remaining) min left. Extend to keep the Mac awake.",
            withExtend: true
        )
    }

    private static func post(title: String, body: String, withExtend: Bool) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        // Only the soon-nudge carries Extend — ended Sessions are over and
        // the menu is the way back.
        content.categoryIdentifier = withExtend ? categoryID : ""
        let request = UNNotificationRequest(
            identifier: "medusa.keepawake.\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}
