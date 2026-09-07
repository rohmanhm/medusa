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
        case keepAwakePane
        case motionProbe(seconds: TimeInterval)
    }

    private let subject: Subject
    private let outputDir: String
    private var controller: SettingsWindowController?
    private var shieldWindow: NSWindow?
    private var probeSamples: [(t: Double, x: CGFloat, y: CGFloat, cx: CGFloat, cy: CGFloat)] = []
    private var probeTimer: Timer?
    private var probeDisplayLink: AnyObject?
    private var probeContent: ShieldContentView?
    private var probeStarted: Date?
    private var probeDuration: TimeInterval = 5

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
        case .keepAwakePane:
            captureKeepAwakePane()
        case .motionProbe(let seconds):
            runMotionProbe(seconds: seconds)
        }
    }

    /// Holds a real `ShieldContentView` (forced drift, live wall clock) in an
    /// off-screen window and samples the stack's layer-driven offset at display
    /// rate (~60–120 Hz). The old 0.25 s timer could PASS a path that still
    /// stuttered — high-rate sampling is what catches frame-step variance and
    /// velocity kicks. Drift rides a transform, so `frame.origin` stays put —
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
        probeDuration = seconds
        probeStarted = Date()

        FileHandle.standardError.write(Data(
            "motion-probe: sampling drift for \(seconds)s at display rate\n".utf8
        ))

        // Sample on the main screen's refresh (not the off-screen view's) so
        // the probe actually fires. A hard deadline Timer is the backstop so a
        // dead display link can never hang the process again.
        if #available(macOS 14.0, *), let screen = NSScreen.main {
            let link = screen.displayLink(target: self, selector: #selector(probeDisplayTick(_:)))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 120, preferred: 120)
            link.add(to: .main, forMode: .common)
            probeDisplayLink = link
        } else {
            let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
                self?.sampleProbe()
            }
            RunLoop.main.add(timer, forMode: .common)
            probeTimer = timer
        }

        // Hard deadline: finish even if the display link never ticks.
        let watchdog = Timer(timeInterval: seconds + 1.0, repeats: false) { [weak self] _ in
            guard let self, self.probeDisplayLink != nil || self.probeTimer != nil else { return }
            FileHandle.standardError.write(Data(
                "motion-probe: watchdog fired — forcing finish with \(self.probeSamples.count) samples\n".utf8
            ))
            self.stopProbeSampling()
            self.finishMotionProbe()
        }
        RunLoop.main.add(watchdog, forMode: .common)
    }

    @objc private func probeDisplayTick(_ link: AnyObject) {
        sampleProbe()
    }

    private func sampleProbe() {
        guard let content = probeContent, let started = probeStarted else { return }
        // Do NOT call layoutSubtreeIfNeeded here — that was the probe itself
        // inducing the once-per-sample layout thrash we are trying to detect.
        let offset = content.stackOffset
        let stack = content.subviews.first { $0 is NSStackView }
        let transform = stack?.layer?.transform ?? CATransform3DIdentity
        let sampleT = Date().timeIntervalSince(started)
        probeSamples.append((sampleT, offset.x, offset.y, transform.m41, transform.m42))

        // Sparse log so a 120 Hz run doesn't drown the terminal.
        if probeSamples.count == 1 || probeSamples.count % 30 == 0 || sampleT >= probeDuration {
            FileHandle.standardError.write(Data(
                String(format: "t=%5.2f offset=(%8.3f, %8.3f) layer=(%8.3f, %8.3f) n=%d\n",
                       sampleT, offset.x, offset.y, transform.m41, transform.m42,
                       probeSamples.count).utf8
            ))
        }

        if sampleT >= probeDuration {
            stopProbeSampling()
            finishMotionProbe()
        }
    }

    private func stopProbeSampling() {
        if #available(macOS 14.0, *) {
            (probeDisplayLink as? CADisplayLink)?.invalidate()
        }
        probeDisplayLink = nil
        probeTimer?.invalidate()
        probeTimer = nil
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

        // Frame-step analysis: consecutive sample deltas should be small and
        // consistent. A triangle-wave reverse, a coalesced display-link hop, or
        // a 1 Hz layout thrash all show up as outlier steps.
        var stepDists: [CGFloat] = []
        var stepDTs: [Double] = []
        for i in 1..<probeSamples.count {
            let a = probeSamples[i - 1]
            let b = probeSamples[i]
            let sdx = b.x - a.x
            let sdy = b.y - a.y
            stepDists.append((sdx * sdx + sdy * sdy).squareRoot())
            stepDTs.append(b.t - a.t)
        }
        let meanStep = stepDists.isEmpty ? 0 : stepDists.reduce(0, +) / CGFloat(stepDists.count)
        let maxStep = stepDists.max() ?? 0
        let meanDT = stepDTs.isEmpty ? 0 : stepDTs.reduce(0, +) / Double(stepDTs.count)
        let maxDT = stepDTs.max() ?? 0
        // Effective sample rate from mean inter-sample gap.
        let sampleHz = meanDT > 0 ? 1.0 / meanDT : 0

        // Velocity continuity: successive frame velocities should not reverse
        // sign with a large magnitude (the triangle-wave hitch signature).
        var velocities: [CGFloat] = []
        for i in 1..<probeSamples.count {
            let a = probeSamples[i - 1]
            let b = probeSamples[i]
            let dt = b.t - a.t
            guard dt > 1e-4 else { continue }
            velocities.append(CGFloat((b.x - a.x) / dt))
        }
        var maxVelKick: CGFloat = 0
        for i in 1..<velocities.count {
            maxVelKick = max(maxVelKick, abs(velocities[i] - velocities[i - 1]))
        }

        FileHandle.standardError.write(Data(
            String(format: """
                motion-probe: samples=%d (%.1f Hz)
                  offset net=(%.3f, %.3f) dist=%.3f span=%.3f
                  layer  net=(%.3f, %.3f) dist=%.3f span=%.3f
                  step mean=%.4f max=%.4f pt  dt mean=%.4f max=%.4f s
                  velocity kick max=%.2f pt/s
                """,
                probeSamples.count, sampleHz,
                dx, dy, dist, offsetSpan,
                ldx, ldy, ldist, layerSpan,
                meanStep, maxStep, meanDT, maxDT,
                maxVelKick).utf8
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

        // High-rate smoothness: nearly every sample should land on a new X
        // (quantized to 0.01 pt). A 1 Hz snap path produces ~seconds distinct.
        let uniqueX = Set(probeSamples.map { Int(($0.x * 100).rounded()) }).count
        let minDistinct = max(30, probeSamples.count / 2)
        if uniqueX < minDistinct {
            FileHandle.standardError.write(Data(
                "motion-probe: FAIL not smooth (distinctX=\(uniqueX) < \(minDistinct); likely stepped snaps)\n".utf8
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

        // Frame-step outlier: a single step >> mean is a hitch (coalesced hop,
        // layout thrash, or velocity kick). Allow 8× mean for ProMotion jitter
        // and the sine's natural speed variation; anything beyond is stutter.
        if meanStep > 0, maxStep > max(meanStep * 8, 2.0) {
            FileHandle.standardError.write(Data(
                "motion-probe: FAIL hitch (maxStep=\(maxStep) ≫ meanStep=\(meanStep))\n".utf8
            ))
            exit(6)
        }

        // Sample rate floor: if we only got ~1 Hz samples the driver is dead
        // and the path is lying via sparse points that happen to look continuous.
        if sampleHz < 20 {
            FileHandle.standardError.write(Data(
                "motion-probe: FAIL low sample rate (\(sampleHz) Hz < 20)\n".utf8
            ))
            exit(7)
        }

        // Velocity kick ceiling: a continuous sine's frame-to-frame Δv is tiny
        // (acceleration * dt). A triangle reverse is 2× peak speed in one frame
        // (~40–60 pt/s). Cap well below that so a wave-shape regression fails.
        if maxVelKick > 25 {
            FileHandle.standardError.write(Data(
                "motion-probe: FAIL velocity kick (max=\(maxVelKick) pt/s > 25; discontinuous path)\n".utf8
            ))
            exit(8)
        }

        FileHandle.standardError.write(Data(
            "motion-probe: PASS offsetSpan=\(offsetSpan) distinctX=\(uniqueX) Hz=\(String(format: "%.1f", sampleHz)) maxStep=\(String(format: "%.4f", maxStep)) kick=\(String(format: "%.2f", maxVelKick))\n".utf8
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

    /// Same trick for the Keep Awake tab — the full settings window can't
    /// launch headlessly, but the pane hosted directly can.
    private func captureKeepAwakePane() {
        let size = NSSize(width: 590, height: 760)
        let window = NSWindow(
            contentRect: NSRect(origin: NSPoint(x: -20000, y: -20000), size: size),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: KeepAwakePane())
        window.orderFront(nil)
        shieldWindow = window
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [self] in
            snap(window: window, name: "pane-keep-awake")
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
        // Drift phases: 0 → screen center (sine midpoint); periodX/4 (= 35 s =
        // 0.583 min with the 140 s X period) → +X extreme of the full-screen
        // travel box. The two shots must land at visibly different offsets.
        let variants: [(name: String, minutes: Double?, dimmed: Bool, motion: ShieldMotionStyle)] = [
            ("lock-screen", nil, false, .wander),
            ("lock-screen-drift-a", 0, false, .drift),
            ("lock-screen-drift-b", 35.0 / 60.0, false, .drift),
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
