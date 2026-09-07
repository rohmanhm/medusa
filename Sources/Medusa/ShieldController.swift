import AppKit
import CoreVideo
import QuartzCore

/// A borderless window that can become key so it absorbs any stray events the
/// tap lets through (e.g. mouse clicks during authentication).
final class ShieldWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Renders the black lock overlay on every display and keeps it in sync with
/// display hot-plug / resolution changes.
///
/// Window level strategy (from the overlay research + the unlock z-order risk):
/// - Locked: `CGShieldingWindowLevel()` — the very top of the level range,
///   above the screen saver and assistive tech, covering the notch and menu bar.
/// - Authenticating: drop to the screen-saver level so the system Touch ID /
///   password dialog (which sits above the screen-saver level but below the
///   shielding level) is visible and clickable. The overlay still covers the
///   desktop and menu bar underneath.
final class ShieldController {
    private var windows: [ShieldWindow] = []
    private(set) var isShown = false

    /// The display layout the current overlays were built for. `screensChanged`
    /// compares against this so a notification that doesn't actually change the
    /// arrangement (macOS fires spurious ones) is ignored instead of tearing
    /// every overlay down and restarting its motion.
    private var screenSignature: [NSRect] = []
    private var rebuildDebounce: Timer?

    private var lockedLevel: NSWindow.Level {
        NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
    }
    private var authLevel: NSWindow.Level {
        NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)))
    }

    func show() {
        guard !isShown else { return }
        isShown = true
        rebuild()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    func hide() {
        NotificationCenter.default.removeObserver(
            self,
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        rebuildDebounce?.invalidate()
        rebuildDebounce = nil
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        screenSignature = []
        isShown = false
    }

    /// Lower the overlay so the system auth dialog shows on top, or raise it
    /// back to full shielding once auth ends. Doubles as the burn-in dim hook:
    /// an auth attempt is the only user interaction a locked shield ever sees,
    /// so it un-dims the content instantly, and a canceled attempt re-arms the
    /// dim grace timer.
    func setAuthMode(_ authenticating: Bool) {
        let level = authenticating ? authLevel : lockedLevel
        for window in windows {
            window.level = level
            (window.contentView as? ShieldContentView)?.setAuthMode(authenticating)
        }
    }

    /// Bring the overlays back after sleep/wake or a session switch without
    /// tearing down content (motion + dim timers keep running). Rebuilds only
    /// when the display layout actually changed while we were away.
    func reaffirm() {
        guard isShown else { return }
        if NSScreen.screens.map(\.frame) != screenSignature {
            rebuild()
            return
        }
        for window in windows {
            window.orderFrontRegardless()
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    /// A display change (hot-plug, resolution, arrangement) means we need fresh
    /// overlays. But external displays — TVs especially — fire a *burst* of
    /// these while they renegotiate HDMI/HDR the moment a full-screen window
    /// appears over them, and some fire with no real change at all. Ignore the
    /// no-ops (by signature) and coalesce the rest (by debounce) so we rebuild
    /// once, after the layout settles — never mid-storm, which is what left one
    /// display's overlay half-built while the other kept animating.
    @objc private func screensChanged() {
        guard isShown else { return }
        guard NSScreen.screens.map(\.frame) != screenSignature else { return }
        rebuildDebounce?.invalidate()
        let timer = Timer(timeInterval: 0.35, repeats: false) { [weak self] _ in
            self?.rebuildDebounce = nil
            self?.rebuild()
        }
        RunLoop.main.add(timer, forMode: .common)
        rebuildDebounce = timer
    }

    private func rebuild() {
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()

        let screens = NSScreen.screens
        screenSignature = screens.map(\.frame)
        for screen in screens {
            let window = ShieldWindow(
                contentRect: screen.frame,
                styleMask: .borderless,
                backing: .buffered,
                defer: false
            )
            window.level = lockedLevel
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            window.backgroundColor = .black
            window.isOpaque = true
            window.hasShadow = false
            window.ignoresMouseEvents = false
            window.isReleasedWhenClosed = false
            window.contentView = ShieldContentView(frame: NSRect(origin: .zero, size: screen.frame.size))
            window.setFrame(screen.frame, display: true)
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            windows.append(window)
        }
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// The visual content of the lock screen: a live clock, an optional owner
/// message, and an unlock hint, centered on a black field. Every element is
/// individually toggleable in Settings; the view reads the preferences once at
/// creation (a shield is rebuilt for every lock, so changes apply next lock).
///
/// Burn-in protection (the OLED-safe-lock-display research, default-on):
/// - **Wander** (default) — DeskClock-style: every couple of minutes the stack
///   fades out, teleports to a random point in the central 60%, and fades back.
///   The strongest positional spread, and plainly visible — so you can tell the
///   protection is live. The first relocate is animated ~1.5 s after lock so the
///   protection doesn't sit still until the next wall-clock boundary.
/// - **Drift** — the stack rides a layer transform along two **sinusoidal** waves
///   of wall-clock time with incommensurate periods. A main-thread `CADisplayLink`
///   (falling back to `CVDisplayLink` on older macOS) writes the phase once per
///   presented frame — no Timer jitter, no off-main hop, no Auto Layout thrash —
///   so the clock glides at the panel's native rate the instant the shield
///   appears. Sine (not triangle) keeps velocity continuous at the turnarounds;
///   the triangle's instant reverse was a visible hitch every half-period.
///   Travel spans the full usable screen (edge-padded so glyphs never clip).
/// - **Dim** — after the grace period the whole stack drops to half alpha
///   (~4× slower OLED wear) and the always-static hint line hides; the first
///   touch un-dims in 0.15 s via `setAuthMode`, before the auth dialog lands.
/// - **Protection notice** — on lock, a one-line summary of what's active fades
///   in near the bottom for a few seconds, then fades away: instant confirmation
///   the protection is on without leaving a static element burning in.
final class ShieldContentView: NSView {
    private let clockLabel = ShieldContentView.makeLabel(size: 84, weight: .thin, alpha: 0.95)
    private let dateLabel = ShieldContentView.makeLabel(size: 17, weight: .regular, alpha: 0.5)
    private let messageLabel = ShieldContentView.makeLabel(size: 16, weight: .regular, alpha: 0.75)
    private let hintLabel = ShieldContentView.makeLabel(size: 15, weight: .medium, alpha: 0.6)
    private let noticeLabel = ShieldContentView.makeLabel(size: 13, weight: .medium, alpha: 0.45)
    private let stack = NSStackView()
    private var clockTimer: Timer?
    /// Main-thread vsync driver (macOS 14+). Stored as `AnyObject` so the property
    /// itself compiles against the macOS 13 deployment target; cast on use.
    /// Fires on the run loop that owns the layer — no off-main callback, no
    /// `DispatchQueue.main.async` hop, no coalesce-induced frame drops. That
    /// hop was a primary stutter source.
    private var caDisplayLink: AnyObject?
    /// Fallback vsync driver for macOS 13 / when `CADisplayLink` can't attach.
    private var cvDisplayLink: CVDisplayLink?
    /// Last-ditch 60 Hz Timer if neither display-link flavor can start.
    private var motionFallbackTimer: Timer?
    /// Last offset written to the stack layer — also what the motion probe reads.
    private(set) var stackOffset: CGPoint = .zero
    /// Cached full-screen travel box so the display-link path never re-measures
    /// the stack (layout thrash was the jank; measure once after first layout).
    private var cachedDriftAmplitude: CGSize?
    private var amplitudeBoundsSize: CGSize = .zero
    /// Coalesce CVDisplayLink → main hops so a busy main queue can't pile up
    /// dozens of stale applyDrift blocks behind one frame. Unused on the
    /// CADisplayLink path (already main-threaded).
    private var driftApplyPending = false

    private let motion: ShieldMotionStyle
    private var centerX: NSLayoutConstraint?
    private var centerY: NSLayoutConstraint?
    private var lastMinuteIndex = -1

    private let dimDuration = AppSettings.shieldDimDuration
    private var dimTimer: Timer?
    private var isDimmed = false

    /// Cached formatters — `DateFormatter` init is cheap-ish, but the 1 Hz clock
    /// tick also dirties Auto Layout; keep the tick itself trivial so it never
    /// contends with the display-link frame budget.
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm"
        return f
    }()
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEEE, MMMM d"
        return f
    }()

    /// Test seams for the snapshot runner: freeze the drift phase at a known
    /// wall-clock minute, start in the dimmed state, or force a motion style
    /// regardless of the saved setting. Production passes nothing.
    private let minutesOverride: Double?

    init(
        frame frameRect: NSRect,
        referenceMinutes: Double? = nil,
        dimImmediately: Bool = false,
        motionOverride: ShieldMotionStyle? = nil
    ) {
        self.minutesOverride = referenceMinutes
        self.motion = motionOverride ?? AppSettings.shieldMotion
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        hintLabel.stringValue = "Press any key or click to unlock"

        let message = AppSettings.lockMessage
        messageLabel.stringValue = message
        messageLabel.lineBreakMode = .byWordWrapping
        messageLabel.preferredMaxLayoutWidth = 640

        var views: [NSView] = []
        if AppSettings.showClock { views.append(clockLabel) }
        if AppSettings.showDate { views.append(dateLabel) }
        if !message.isEmpty {
            if !views.isEmpty { views.append(spacer(18)) }
            views.append(messageLabel)
        }
        if AppSettings.showHint {
            if !views.isEmpty { views.append(spacer(24)) }
            views.append(hintLabel)
        }

        views.forEach { stack.addArrangedSubview($0) }
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        // Layer-backed so continuous drift can ride `transform` at display rate
        // without thrashing Auto Layout every frame (that was the jank source).
        stack.wantsLayer = true
        if let layer = stack.layer {
            layer.actions = [
                "position": NSNull(),
                "bounds": NSNull(),
                "transform": NSNull()
            ]
        }
        addSubview(stack)
        let centerX = stack.centerXAnchor.constraint(equalTo: centerXAnchor)
        let centerY = stack.centerYAnchor.constraint(equalTo: centerYAnchor)
        NSLayoutConstraint.activate([centerX, centerY])
        self.centerX = centerX
        self.centerY = centerY

        let hasContent = !views.isEmpty
        if hasContent {
            switch motion {
            case .drift:
                // Place at the live wall-clock phase immediately, then the display
                // link keeps gliding on every refresh from the first frame onward.
                applyDrift()
            case .wander:
                // Seed a non-center resting spot, then animate a real relocate
                // shortly after lock so "is protection on?" is answered by motion
                // the user can actually see — not a 0–2 min wait for a minute boundary.
                relocate(animated: false)
                if minutesOverride == nil {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                        guard let self, self.motion == .wander else { return }
                        self.relocate(animated: true)
                    }
                }
            case .off:
                break
            }
            if dimImmediately {
                isDimmed = true
                stack.alphaValue = 0.5
                hintLabel.alphaValue = 0
            } else {
                scheduleDim()
            }
        }

        // Bottom-pinned, independent of the stack so its fade never reflows the
        // clock. Flashed only in the live app (a frozen-phase snapshot would
        // catch it mid-fade); pinned to the view, not the stack, so it doesn't
        // ride the motion. Skipped on an empty shield — nothing static to guard.
        if hasContent, let summary = Self.protectionSummary(motion: motion, dimDuration: dimDuration) {
            noticeLabel.stringValue = summary
            noticeLabel.alphaValue = 0
            noticeLabel.translatesAutoresizingMaskIntoConstraints = false
            addSubview(noticeLabel)
            NSLayoutConstraint.activate([
                noticeLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
                noticeLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -32)
            ])
            if minutesOverride == nil { flashProtectionNotice() }
        }

        if AppSettings.showClock || AppSettings.showDate {
            tick()
            let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in self?.tick() }
            RunLoop.main.add(timer, forMode: .common)
            clockTimer = timer
        } else if hasContent && motion == .wander {
            // Wander still needs the 1 s tick to catch wall-clock minute boundaries
            // even when the clock/date labels are hidden.
            tick()
            let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in self?.tick() }
            RunLoop.main.add(timer, forMode: .common)
            clockTimer = timer
        }

        if hasContent && motion == .drift && minutesOverride == nil {
            // Seed the phase now; the display link itself is started from
            // viewDidMoveToWindow so it binds to a real screen. Creating a
            // view-scoped CADisplayLink in init (no window yet) silently never
            // fires — which is exactly how the motion probe hung forever.
            applyDrift()
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        clockTimer?.invalidate()
        stopDisplayLink()
        dimTimer?.invalidate()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Bind the vsync driver to a real screen only once we have a window.
        // Tear down when detached so a rebuild doesn't leave a dangling link
        // writing into a deallocated view hierarchy.
        guard motion == .drift, minutesOverride == nil else { return }
        if window != nil {
            applyDrift()
            startDisplayLink()
        } else {
            stopDisplayLink()
        }
    }

    override func layout() {
        super.layout()
        // Amplitude depends on bounds + stack size. Recompute ONLY when the
        // view actually resized — the 1 Hz clock tick dirties Auto Layout
        // (label string change → intrinsic size may change), and re-applying
        // the transform from layout was fighting the display link mid-frame.
        // That once-per-second re-entry was a measurable hitch source.
        guard motion == .drift else { return }
        let sizeChanged = amplitudeBoundsSize != bounds.size
        let needsFirstMeasure = cachedDriftAmplitude == nil
        guard sizeChanged || needsFirstMeasure else { return }
        cachedDriftAmplitude = nil
        amplitudeBoundsSize = bounds.size
        applyDrift()
    }

    /// Mirrors `ShieldController.setAuthMode`: an auth attempt is the shield's
    /// only notion of "the user is here" — un-dim instantly and pause the grace
    /// timer while the dialog is up; a canceled attempt re-arms it.
    func setAuthMode(_ authenticating: Bool) {
        if authenticating {
            dimTimer?.invalidate()
            undim()
        } else {
            scheduleDim()
        }
    }

    private func tick() {
        let now = Date()
        // Only write when the minute (or date) actually changed — a no-op
        // string assignment still dirties Auto Layout and can kick `layout()`
        // once a second, which is exactly the hitch cadence a staring eye
        // picks up on a slow glide.
        let nextTime = Self.timeFormatter.string(from: now)
        if clockLabel.stringValue != nextTime {
            clockLabel.stringValue = nextTime
        }
        let nextDate = Self.dateFormatter.string(from: now)
        if dateLabel.stringValue != nextDate {
            dateLabel.stringValue = nextDate
        }

        // Drift is owned by the display link. Wander still steps on whole
        // wall-clock minute boundaries so the relocate cadence stays honest.
        guard motion == .wander else { return }
        let minuteIndex = Int(wallClockMinutes.rounded(.down))
        guard minuteIndex != lastMinuteIndex else { return }
        let isFirstTick = lastMinuteIndex == -1
        lastMinuteIndex = minuteIndex
        // Skip the first boundary so we don't double-fire with the post-lock
        // "immediate" relocate scheduled from init.
        guard !isFirstTick else { return }
        if minuteIndex.isMultiple(of: Self.wanderIntervalMinutes) {
            relocate(animated: true)
        }
    }

    // MARK: Drift (incommensurate sinusoids)

    /// Periods in **seconds**. Two incommensurate sinusoids so the 2-D path
    /// doesn't visibly loop for a long time. Periods are longer than the old
    /// triangular 90/143 because a sine's peak speed is π/2× a triangle's of
    /// the same period — keep peak velocity calm across the full-screen box.
    ///
    /// On a 1728×1080 canvas the usable half-box is roughly ±(864−pad)×±(540−pad);
    /// full X travel ~1600 pt over a 140 s sine ⇒ peak ≈ **18 pt/s** — visible
    /// and calm, not a screensaver bounce. Sine (not triangle) is load-bearing:
    /// a triangular wave *snaps* velocity at every peak (Δv = 2 × peak speed),
    /// which the eye reads as a hitch even when frame timing is perfect.
    private static let driftPeriodX = 140.0
    private static let driftPeriodY = 221.0

    /// Full travel per axis = twice the max offset from center. Uses the whole
    /// usable screen: half the view minus half the stack, with a small edge pad
    /// so glyphs never kiss the bezel. No artificial 10%/120-pt cap. Cached
    /// after the first successful measure so the display-link path stays cheap.
    private var driftAmplitude: CGSize {
        if let cachedDriftAmplitude, amplitudeBoundsSize == bounds.size {
            return cachedDriftAmplitude
        }
        let fitted = stack.fittingSize
        let stackSize = stack.bounds.size.width > 1 ? stack.bounds.size : fitted
        // If we still don't know the stack size, fall back to a generous fraction
        // of the view — better a slightly-too-large box for one frame than zero
        // motion while waiting for layout.
        let w = stackSize.width > 1 ? stackSize.width : min(bounds.width * 0.4, 400)
        let h = stackSize.height > 1 ? stackSize.height : min(bounds.height * 0.3, 200)
        let pad: CGFloat = 24
        let halfW = max(0, (bounds.width - w) / 2 - pad)
        let halfH = max(0, (bounds.height - h) / 2 - pad)
        let amplitude = CGSize(width: halfW * 2, height: halfH * 2)
        if stack.bounds.size.width > 1 || fitted.width > 1 {
            cachedDriftAmplitude = amplitude
            amplitudeBoundsSize = bounds.size
        }
        return amplitude
    }

    /// Continuous sinusoid spanning 0 → amplitude → 0 → … over one period.
    /// Velocity is itself a cosine — continuous at the peaks — so the turnaround
    /// eases instead of kicking. Phase 0 sits at the midpoint (offset 0 after
    /// centering), matching the old triangle's start for snapshot stability at
    /// the "a" end; the "b" end still lands near an axis extreme.
    private static func glide(_ phase: Double, amplitude: CGFloat, period: Double) -> CGFloat {
        guard period > 0, amplitude > 0 else { return 0 }
        // sin maps [0, 2π) → [-1, 1]; shift+scale into [0, amplitude].
        let angle = (phase / period) * 2.0 * Double.pi
        return amplitude * CGFloat((sin(angle) + 1) * 0.5)
    }

    /// Wall-clock phase in **seconds** for continuous drift, or the frozen
    /// snapshot override (stored in minutes — converted here so production and
    /// snapshot stay independent).
    private var wallClockSeconds: Double {
        if let minutesOverride { return minutesOverride * 60 }
        return Date().timeIntervalSince1970
    }

    /// Whole minutes of wall clock — used by wander's boundary detector. The
    /// snapshot override freezes this too so a frozen-phase shot is stable.
    private var wallClockMinutes: Double {
        minutesOverride ?? Date().timeIntervalSince1970 / 60
    }

    /// Write the current wall-clock phase as a layer transform. Called once per
    /// display refresh; constraints stay pinned at center so Auto Layout never
    /// re-solves mid-glide (that thrash was the jank).
    private func applyDrift() {
        let amplitude = driftAmplitude
        let phase = wallClockSeconds
        // Centered on screen center: offsets span ±amplitude/2.
        let offset = CGPoint(
            x: Self.glide(phase, amplitude: amplitude.width, period: Self.driftPeriodX) - amplitude.width / 2,
            y: Self.glide(phase, amplitude: amplitude.height, period: Self.driftPeriodY) - amplitude.height / 2
        )
        setStackOffset(offset, animated: false)
    }

    // MARK: Display-link driver

    private func startDisplayLink() {
        // Already running — don't rebuild on every viewDidMoveToWindow bounce.
        if caDisplayLink != nil || cvDisplayLink != nil || motionFallbackTimer != nil {
            return
        }

        // Prefer CADisplayLink: main-thread, ProMotion-aware, no off-main hop.
        // Bind to the window's screen (or main screen) — NOT the view — so the
        // link still fires for off-screen probe windows and for shields that
        // haven't been ordered front yet. A view-scoped link created with no
        // screen association is a silent no-op.
        if #available(macOS 14.0, *) {
            let screen = window?.screen ?? NSScreen.main
            if let screen {
                let link = screen.displayLink(target: self, selector: #selector(displayLinkFired(_:)))
                // Prefer the panel's max refresh (ProMotion 120) so the glide
                // isn't artificially capped at 60. The system still drops under
                // thermal pressure via the 30 Hz floor.
                link.preferredFrameRateRange = CAFrameRateRange(
                    minimum: 30,
                    maximum: 120,
                    preferred: 120
                )
                link.add(to: .main, forMode: .common)
                caDisplayLink = link
                return
            }
        }

        startCVDisplayLinkFallback()
    }

    @objc private func displayLinkFired(_ link: AnyObject) {
        // Already on main. Phase is wall-clock, so a late fire still lands on
        // the correct position — we never "catch up" by applying stale frames.
        // Signature is `AnyObject` (not `CADisplayLink`) so this selector
        // compiles on the macOS 13 deployment target; CADisplayLink only
        // constructs the link under the `#available(macOS 14.0, *)` branch.
        applyDrift()
    }

    /// macOS 13 / last-resort path: CVDisplayLink off the main display, hopped
    /// onto main with coalescing. Correct but coarser under main-queue load.
    private func startCVDisplayLinkFallback() {
        var link: CVDisplayLink?
        guard CVDisplayLinkCreateWithCGDisplay(CGMainDisplayID(), &link) == kCVReturnSuccess,
              let link
        else {
            let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
                self?.applyDrift()
            }
            RunLoop.main.add(timer, forMode: .common)
            motionFallbackTimer = timer
            return
        }
        let callback: CVDisplayLinkOutputCallback = { _, _, _, _, _, userInfo in
            guard let userInfo else { return kCVReturnSuccess }
            let view = Unmanaged<ShieldContentView>.fromOpaque(userInfo).takeUnretainedValue()
            if view.driftApplyPending { return kCVReturnSuccess }
            view.driftApplyPending = true
            DispatchQueue.main.async {
                view.driftApplyPending = false
                view.applyDrift()
            }
            return kCVReturnSuccess
        }
        CVDisplayLinkSetOutputCallback(link, callback, Unmanaged.passUnretained(self).toOpaque())
        CVDisplayLinkStart(link)
        cvDisplayLink = link
    }

    private func stopDisplayLink() {
        if #available(macOS 14.0, *) {
            (caDisplayLink as? CADisplayLink)?.invalidate()
        }
        caDisplayLink = nil
        if let cvDisplayLink {
            CVDisplayLinkStop(cvDisplayLink)
            self.cvDisplayLink = nil
        }
        motionFallbackTimer?.invalidate()
        motionFallbackTimer = nil
        driftApplyPending = false
    }

    // MARK: Wander (DeskClock relocation)

    /// Relocate this often (whole wall-clock minutes). Short enough that a wander
    /// is easy to catch in a normal lock, long enough not to nag.
    private static let wanderIntervalMinutes = 2

    private func relocate(animated: Bool) {
        let size = stack.fittingSize
        let travel = CGSize(
            width: max(0, (bounds.width * 0.6 - size.width) / 2),
            height: max(0, (bounds.height * 0.6 - size.height) / 2)
        )
        let target = CGPoint(
            x: CGFloat.random(in: -travel.width...travel.width),
            y: CGFloat.random(in: -travel.height...travel.height)
        )
        guard animated else {
            setStackOffset(target, animated: false)
            return
        }
        // DeskClock pattern: fade out, teleport, fade back in. ~1.4 s a side so
        // the clock is only briefly absent, not gone for six seconds.
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 1.4
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            stack.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self else { return }
            self.setStackOffset(target, animated: false)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 1.4
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                self.stack.animator().alphaValue = self.isDimmed ? 0.5 : 1.0
            }
        })
    }

    private func setStackOffset(_ offset: CGPoint, animated: Bool) {
        // Skip the no-op write — identical transforms still go through
        // CATransaction and can force a commit. Sub-point equality is enough;
        // the display-link path advances continuously so this only fires when
        // something re-applies the same phase (layout, snapshot freeze).
        if abs(offset.x - stackOffset.x) < 0.001, abs(offset.y - stackOffset.y) < 0.001 {
            return
        }
        stackOffset = offset
        // Continuous drift uses the layer transform so we never re-solve Auto
        // Layout at display rate. Wander still teleports via the same path
        // (instant) — its fade is alpha-only and doesn't need a layout hop.
        // Constraints stay at center forever after init; do NOT poke them here
        // (writing `.constant` dirties Auto Layout every frame → jank).
        let applyTransform = { [self] in
            // CALayer geometry is y-up; AppKit view coordinates are y-up too for
            // affine translation in the layer's superlayer space when the view
            // is layer-backed without a flipped geometry — translating by
            // (offset.x, offset.y) matches the old constraint constants.
            stack.layer?.transform = CATransform3DMakeTranslation(offset.x, offset.y, 0)
        }
        guard animated else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            applyTransform()
            CATransaction.commit()
            return
        }
        // Animated path kept for API symmetry; wander doesn't use it for
        // position (fade-teleport-fade sets offset with animated: false).
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 1.0
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            context.allowsImplicitAnimation = true
            applyTransform()
        }
    }

    // MARK: Dim after grace

    private func scheduleDim() {
        dimTimer?.invalidate()
        guard dimDuration > 0 else { return }
        let timer = Timer(timeInterval: dimDuration, repeats: false) { [weak self] _ in self?.dim() }
        RunLoop.main.add(timer, forMode: .common)
        dimTimer = timer
    }

    private func dim() {
        guard !isDimmed else { return }
        isDimmed = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 2.0
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            // Halving every label's alpha cuts emitted luminance to ~22–25%
            // (gamma), ≥3× slower OLED wear; the hint is pixel-static and
            // nonessential, so it goes dark entirely.
            stack.animator().alphaValue = 0.5
            hintLabel.animator().alphaValue = 0
        }
    }

    private func undim() {
        guard isDimmed else { return }
        isDimmed = false
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            stack.animator().alphaValue = 1.0
            hintLabel.animator().alphaValue = 1.0
        }
    }

    // MARK: Protection notice

    /// A plain-language line naming what's active — "Screen protection ·
    /// wander + auto-dim". Nil when nothing is on (so no notice appears).
    private static func protectionSummary(motion: ShieldMotionStyle, dimDuration: TimeInterval) -> String? {
        var parts: [String] = []
        switch motion {
        case .drift: parts.append("drift")
        case .wander: parts.append("wander")
        case .off: break
        }
        if dimDuration > 0 { parts.append("auto-dim") }
        guard !parts.isEmpty else { return nil }
        return "Screen protection · " + parts.joined(separator: " + ")
    }

    /// Fade the notice in on lock, hold it briefly, then fade it away — a
    /// transient confirmation that leaves nothing static to burn in.
    private func flashProtectionNotice() {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.5
            noticeLabel.animator().alphaValue = 0.45
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { [weak self] in
            guard let self else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 1.0
                self.noticeLabel.animator().alphaValue = 0
            }
        }
    }

    private func spacer(_ height: CGFloat) -> NSView {
        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.heightAnchor.constraint(equalToConstant: height).isActive = true
        return view
    }

    private static func makeLabel(size: CGFloat, weight: NSFont.Weight, alpha: CGFloat) -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = NSColor.white.withAlphaComponent(alpha)
        label.alignment = .center
        label.isBezeled = false
        label.drawsBackground = false
        label.isEditable = false
        label.isSelectable = false
        return label
    }
}
