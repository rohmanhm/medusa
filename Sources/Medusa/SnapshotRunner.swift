import AppKit
import SwiftUI

/// Dev harness (`--snapshot-settings <dir>`, `--snapshot-shield <dir>`,
/// `--snapshot-lockpane <dir>`): renders each Settings tab — or the
/// lock-screen shield, or the Lock Screen pane hosted directly — to a PNG so
/// UI work can be eyeballed without Screen Recording permission. Sits
/// alongside the `--self-test` family — verification you can run headlessly.
///
/// `--snapshot-lockpane` exists because the full settings window's toolbar-tab
/// machinery throws (and swallows) an exception under a headless launch on
/// current macOS — hosting the pane directly sidesteps that and still shows
/// the real SwiftUI form.
final class SnapshotRunner: NSObject, NSApplicationDelegate {
    enum Subject {
        case settings
        case shield
        case lockPane
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
        case .lockPane:
            captureLockPane()
        }
    }

    /// Hosts `LockScreenPane` directly in an off-screen borderless window —
    /// the same trick `captureShield` uses — so the pane's real SwiftUI render
    /// can be verified even while the full settings window can't launch
    /// headlessly.
    private func captureLockPane() {
        let size = NSSize(width: 590, height: 780)
        let window = NSWindow(
            contentRect: NSRect(origin: NSPoint(x: -20000, y: -20000), size: size),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: LockScreenPane())
        window.orderFront(nil)
        shieldWindow = window
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [self] in
            snap(window: window, name: "pane-lock-screen")
            exit(0)
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
    ///
    /// Alongside the doc image, three burn-in-protection variants render with
    /// the drift phase frozen (or the dim state forced), and each variant's
    /// stack frame is logged — so drift deltas and the dim alphas can be
    /// asserted from the run output instead of pixel-diffing.
    private func captureShield() {
        UserDefaults.standard.register(defaults: [
            AppSettings.Keys.lockMessage: "Back in 10 — the agents keep working"
        ])
        // (name, frozen drift phase in wall-clock minutes, start dimmed)
        let variants: [(name: String, minutes: Double?, dimmed: Bool)] = [
            ("lock-screen", nil, false),
            ("lock-screen-drift-a", 0, false),
            ("lock-screen-drift-b", 41.5, false),
            ("lock-screen-dimmed", 0, true)
        ]
        captureShieldVariants(variants)
    }

    private func captureShieldVariants(_ variants: [(name: String, minutes: Double?, dimmed: Bool)]) {
        guard let variant = variants.first else {
            exit(0)
        }
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
        let content = ShieldContentView(
            frame: NSRect(origin: .zero, size: size),
            referenceMinutes: variant.minutes,
            dimImmediately: variant.dimmed
        )
        window.contentView = content
        window.orderFront(nil)
        shieldWindow = window
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [self] in
            content.layoutSubtreeIfNeeded()
            if let stack = content.subviews.first {
                let origin = stack.frame.origin
                FileHandle.standardError.write(Data(
                    "\(variant.name): stack origin=(\(origin.x), \(origin.y)) alpha=\(stack.alphaValue)\n".utf8
                ))
            }
            snap(window: window, name: variant.name)
            window.orderOut(nil)
            captureShieldVariants(Array(variants.dropFirst()))
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
