import AppKit

/// Dev harness (`--snapshot-settings <dir>`, `--snapshot-shield <dir>`):
/// renders each Settings tab — or the lock-screen shield — to a PNG so UI work
/// can be eyeballed without Screen Recording permission. Sits alongside the
/// `--self-test` family — verification you can run headlessly.
final class SnapshotRunner: NSObject, NSApplicationDelegate {
    enum Subject {
        case settings
        case shield
    }

    private let subject: Subject
    private let outputDir: String
    private var controller: SettingsWindowController?
    private var shieldWindow: NSWindow?

    init(subject: Subject, outputDir: String) {
        self.subject = subject
        self.outputDir = outputDir
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppSettings.registerDefaults()
        switch subject {
        case .settings:
            let controller = SettingsWindowController()
            self.controller = controller
            controller.show(tab: .general)
            capture(tabs: Array(SettingsWindowController.Tab.allCases))
        case .shield:
            captureShield()
        }
    }

    private func capture(tabs: [SettingsWindowController.Tab]) {
        guard let tab = tabs.first else {
            exit(0)
        }
        controller?.show(tab: tab)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [self] in
            snap(window: controller?.window, name: "tab-\(tab.rawValue)-\(tab.label.replacingOccurrences(of: " ", with: ""))")
            capture(tabs: Array(tabs.dropFirst()))
        }
    }

    /// Renders the real `ShieldContentView` — the exact view a lock shows — at
    /// MacBook-ish proportions, in a window parked far off-screen so nothing
    /// flashes over the session and no input tap is ever engaged. The demo
    /// message goes through the registration domain, so it never touches the
    /// user's saved settings.
    private func captureShield() {
        UserDefaults.standard.register(defaults: [
            AppSettings.Keys.lockMessage: "Back in 10 — the agents keep working"
        ])
        let size = NSSize(width: 1728, height: 1080)
        let window = NSWindow(
            contentRect: NSRect(origin: NSPoint(x: -20000, y: -20000), size: size),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.backgroundColor = .black
        window.isOpaque = true
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.contentView = ShieldContentView(frame: NSRect(origin: .zero, size: size))
        window.orderFront(nil)
        shieldWindow = window
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [self] in
            snap(window: window, name: "lock-screen")
            exit(0)
        }
    }

    private func snap(window: NSWindow?, name: String) {
        guard let window,
              let frameView = window.contentView?.superview,
              let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds)
        else { return }
        frameView.cacheDisplay(in: frameView.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        let url = URL(fileURLWithPath: outputDir).appendingPathComponent("\(name).png")
        try? data.write(to: url)
        FileHandle.standardError.write(Data("wrote \(url.path)\n".utf8))
    }
}
