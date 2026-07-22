import AppKit
import SwiftUI

/// Dev harness (`--snapshot-settings <dir>`, `--snapshot-shield <dir>`,
/// `--snapshot-lockpane <dir>`, `--motion-probe [seconds]`): renders each
/// Settings tab — or the lock-screen shield, or the Lock Screen pane hosted
/// directly — to a PNG so UI work can be eyeballed without Screen Recording
/// permission. Sits alongside the `--self-test` family — verification you can
/// run headlessly.
///
/// `--snapshot-lockpane` exists because the full settings window's toolbar-tab
/// machinery throws (and swallows) an exception under a headless launch on
/// current macOS — hosting the pane directly sidesteps that and still shows
/// the real SwiftUI form.
///
/// `--motion-probe` samples the real `ShieldContentView` stack origin over time
/// under forced drift — the red/green loop for "gentle drift doesn't move."
final class SnapshotRunner: NSObject, NSApplicationDelegate {
    enum Subject {
        case settings
        case shield
        case lockPane
        case motionProbe(seconds: TimeInterval)
    }

    private let subject: Subject
    private let outputDir: String
    private var controller: SettingsWindowController?
    private var shieldWindow: NSWindow?
    private var probeSamples: [(t: Double, x: CGFloat, y: CGFloat, cx: CGFloat, cy: CGFloat)] = []
    private var probeTimer: Timer?
    private var probeContent: ShieldContentView?

    init(subject: Subject, outputDir: String = "/tmp") {
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
        case .motionProbe(let seconds):
            runMotionProbe(seconds: seconds)
        }
    }

    /// Holds a real `ShieldContentView` (forced drift, live wall clock) in an
    /// off-screen window and samples the stack's layer-driven offset every
    /// 0.25 s. Drift rides a transform now, so `frame.origin` stays put —
    /// `stackOffset` is the ground truth.
    private func runMotionProbe(seconds: TimeInterval) {
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
            motionOverride: .drift
        )
        window.contentView = content
        window.orderFront(nil)
        // Force a layout pass so full-area amplitude can measure the stack.
        content.layoutSubtreeIfNeeded()
        shieldWindow = window
        probeContent = content

        let started = Date()
        FileHandle.standardError.write(Data(
            "motion-probe: sampling drift for \(seconds)s (tick every 0.25s)\n".utf8
        ))

        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self else { return }
            content.layoutSubtreeIfNeeded()
            // Primary signal: the layer-transform offset ShieldContentView exposes.
            let offset = content.stackOffset
            // Secondary: read the transform matrix directly (m41/m42 = tx/ty).
            let stack = content.subviews.first { $0 is NSStackView }
            let t = stack?.layer?.transform ?? CATransform3DIdentity
            let sampleT = Date().timeIntervalSince(started)
            self.probeSamples.append((sampleT, offset.x, offset.y, t.m41, t.m42))
            FileHandle.standardError.write(Data(
                String(format: "t=%5.2f offset=(%8.3f, %8.3f) layer=(%8.3f, %8.3f)\n",
                       sampleT, offset.x, offset.y, t.m41, t.m42).utf8
            ))
            if sampleT >= seconds {
                self.probeTimer?.invalidate()
                self.finishMotionProbe()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        probeTimer = timer
    }

    private func finishMotionProbe() {
        guard let first = probeSamples.first, let last = probeSamples.last else {
            FileHandle.standardError.write(Data("motion-probe: FAIL no samples\n".utf8))
            exit(3)
        }
        let dx = last.x - first.x
        let dy = last.y - first.y
        let dist = (dx * dx + dy * dy).squareRoot()
        let ldx = last.cx - first.cx
        let ldy = last.cy - first.cy
        let ldist = (ldx * ldx + ldy * ldy).squareRoot()

        // Peak-to-peak across samples (catches back-and-forth that nets ~0).
        let xs = probeSamples.map(\.x)
        let ys = probeSamples.map(\.y)
        let offsetSpan = hypot((xs.max() ?? 0) - (xs.min() ?? 0),
                               (ys.max() ?? 0) - (ys.min() ?? 0))
        let layerSpan = hypot(
            (probeSamples.map(\.cx).max() ?? 0) - (probeSamples.map(\.cx).min() ?? 0),
            (probeSamples.map(\.cy).max() ?? 0) - (probeSamples.map(\.cy).min() ?? 0)
        )

        FileHandle.standardError.write(Data(
            String(format: """
                motion-probe: samples=%d
                  offset net=(%.3f, %.3f) dist=%.3f span=%.3f
                  layer  net=(%.3f, %.3f) dist=%.3f span=%.3f
                """,
                probeSamples.count, dx, dy, dist, offsetSpan,
                ldx, ldy, ldist, layerSpan).utf8
        ))

        // Full-area drift should cover far more than 20 pt in 5 s. Keep 20 as
        // the floor so a regression to the old tiny box still fails loudly.
        let minVisibleSpan: CGFloat = 20
        if offsetSpan < minVisibleSpan {
            FileHandle.standardError.write(Data(
                "motion-probe: FAIL imperceptible (offsetSpan=\(offsetSpan) < \(minVisibleSpan))\n".utf8
            ))
            exit(3)
        }

        // Smooth glide: with a 0.25 s sample rate, a continuous animation should
        // produce many distinct X positions — not one jump per whole second.
        let uniqueX = Set(probeSamples.map { Int(($0.x * 10).rounded()) }).count
        let minDistinct = max(8, probeSamples.count / 3)
        if uniqueX < minDistinct {
            FileHandle.standardError.write(Data(
                "motion-probe: FAIL not smooth (distinctX=\(uniqueX) < \(minDistinct); likely 1 Hz snaps)\n".utf8
            ))
            exit(4)
        }

        // Layer transform and the public offset must agree — catches a path that
        // updates the property but forgets to write the layer (or vice versa).
        if abs(offsetSpan - layerSpan) > 1.0 {
            FileHandle.standardError.write(Data(
                "motion-probe: FAIL offset/layer desync (offsetSpan=\(offsetSpan) layerSpan=\(layerSpan))\n".utf8
            ))
            exit(5)
        }

        FileHandle.standardError.write(Data(
            "motion-probe: PASS offsetSpan=\(offsetSpan) distinctX=\(uniqueX)\n".utf8
        ))
        exit(0)
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
    /// Alongside the doc image, burn-in-protection variants render with the
    /// motion style forced and the drift phase frozen (or the dim state forced),
    /// and each variant's stack frame is logged — so drift deltas, a real wander
    /// offset, and the dim alphas can be asserted from the run output instead of
    /// pixel-diffing. The motion override is a test seam; the real app reads the
    /// saved setting once per lock.
    private func captureShield() {
        UserDefaults.standard.register(defaults: [
            AppSettings.Keys.lockMessage: "Back in 10 — the agents keep working"
        ])
        // (name, frozen drift phase in wall-clock minutes, start dimmed, motion).
        // Drift phases 0 and 0.75 min (= 45 s) are the two ends of the X
        // zigzag (period 90 s), so the two drift shots sit at opposite edges
        // of the full-screen travel box.
        let variants: [(name: String, minutes: Double?, dimmed: Bool, motion: ShieldMotionStyle)] = [
            ("lock-screen", nil, false, .wander),
            ("lock-screen-drift-a", 0, false, .drift),
            ("lock-screen-drift-b", 0.75, false, .drift),
            ("lock-screen-wander", nil, false, .wander),
            ("lock-screen-dimmed", 0, true, .drift)
        ]
        captureShieldVariants(variants)
    }

    private func captureShieldVariants(
        _ variants: [(name: String, minutes: Double?, dimmed: Bool, motion: ShieldMotionStyle)]
    ) {
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
            dimImmediately: variant.dimmed,
            motionOverride: variant.motion
        )
        window.contentView = content
        window.orderFront(nil)
        shieldWindow = window
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [self] in
            content.layoutSubtreeIfNeeded()
            // Drift rides a layer transform; log that offset (not frame.origin,
            // which stays at the constraint-centered rest position).
            let offset = content.stackOffset
            let alpha = content.subviews.first { $0 is NSStackView }?.alphaValue ?? -1
            FileHandle.standardError.write(Data(
                "\(variant.name): stack offset=(\(offset.x), \(offset.y)) alpha=\(alpha)\n".utf8
            ))
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
