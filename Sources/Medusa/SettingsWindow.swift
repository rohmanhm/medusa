import AppKit
import SwiftUI

/// The Settings window: System Settings-style toolbar tabs, each hosting a
/// SwiftUI grouped form. This is also the first-run experience — when
/// permissions are missing the window opens straight on the Permissions tab,
/// which absorbs the old onboarding flow.
final class SettingsWindowController: NSWindowController {
    enum Tab: Int, CaseIterable {
        case general
        case lockScreen
        case permissions

        var label: String {
            switch self {
            case .general: return "General"
            case .lockScreen: return "Lock Screen"
            case .permissions: return "Permissions"
            }
        }

        var symbol: String {
            switch self {
            case .general: return "gearshape"
            case .lockScreen: return "lock.display"
            case .permissions: return "checkmark.shield"
            }
        }

        /// Fixed pane size; the tab controller animates the window between
        /// these when switching tabs, System Settings-style.
        var size: NSSize {
            switch self {
            case .general: return NSSize(width: 590, height: 440)
            case .lockScreen: return NSSize(width: 590, height: 645)
            case .permissions: return NSSize(width: 590, height: 370)
            }
        }

        @ViewBuilder fileprivate var pane: some View {
            switch self {
            case .general: GeneralPane()
            case .lockScreen: LockScreenPane()
            case .permissions: PermissionsPane()
            }
        }
    }

    private let tabController = NSTabViewController()

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 590, height: 480),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.titlebarSeparatorStyle = .automatic
        self.init(window: window)

        tabController.tabStyle = .toolbar
        tabController.canPropagateSelectedChildViewControllerTitle = true
        for tab in Tab.allCases {
            let host = NSHostingController(rootView: AnyView(tab.pane))
            host.title = tab.label
            host.preferredContentSize = tab.size
            let item = NSTabViewItem(viewController: host)
            item.label = tab.label
            item.image = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: tab.label)
            tabController.addTabViewItem(item)
        }
        window.contentViewController = tabController
        window.center()
    }

    func show(tab: Tab? = nil) {
        if let tab { tabController.selectedTabViewItemIndex = tab.rawValue }
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}
