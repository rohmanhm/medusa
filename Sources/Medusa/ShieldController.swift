import AppKit

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
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
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

    @objc private func screensChanged() {
        if isShown { rebuild() }
    }

    private func rebuild() {
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()

        for screen in NSScreen.screens {
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
/// Burn-in protection (the OLED-safe-lock-display research, both default-on):
/// - **Drift** — the stack's center constraints follow two triangular waves of
///   wall-clock minutes with AOSP's incommensurate 83/521-minute periods, so
///   the path never repeats and re-locks continue the pattern instead of
///   restarting at center. Steps land on minute boundaries, under a point each
///   — invisible, but hours of lock spread every glyph over a 32×48 pt band.
/// - **Wander** (opt-in) — DeskClock-style: every 15 minutes the stack fades
///   out, teleports to a random point in the central 60%, and fades back.
/// - **Dim** — after the grace period the whole stack drops to half alpha
///   (~4× slower OLED wear) and the always-static hint line hides; the first
///   touch un-dims in 0.15 s via `setAuthMode`, before the auth dialog lands.
final class ShieldContentView: NSView {
    private let clockLabel = ShieldContentView.makeLabel(size: 84, weight: .thin, alpha: 0.95)
    private let dateLabel = ShieldContentView.makeLabel(size: 17, weight: .regular, alpha: 0.5)
    private let messageLabel = ShieldContentView.makeLabel(size: 16, weight: .regular, alpha: 0.75)
    private let hintLabel = ShieldContentView.makeLabel(size: 15, weight: .medium, alpha: 0.6)
    private let stack = NSStackView()
    private var clockTimer: Timer?

    private let motion = AppSettings.shieldMotion
    private var centerX: NSLayoutConstraint?
    private var centerY: NSLayoutConstraint?
    private var lastMinuteIndex = -1

    private let dimDuration = AppSettings.shieldDimDuration
    private var dimTimer: Timer?
    private var isDimmed = false

    /// Test seams for the snapshot runner: freeze the drift phase at a known
    /// wall-clock minute, or start in the dimmed state. Production passes nothing.
    private let minutesOverride: Double?

    init(frame frameRect: NSRect, referenceMinutes: Double? = nil, dimImmediately: Bool = false) {
        self.minutesOverride = referenceMinutes
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
        addSubview(stack)
        let centerX = stack.centerXAnchor.constraint(equalTo: centerXAnchor)
        let centerY = stack.centerYAnchor.constraint(equalTo: centerYAnchor)
        NSLayoutConstraint.activate([centerX, centerY])
        self.centerX = centerX
        self.centerY = centerY

        let hasContent = !views.isEmpty
        if hasContent {
            switch motion {
            case .drift: applyDrift(animated: false)
            case .wander: relocate(animated: false)
            case .off: break
            }
            if dimImmediately {
                isDimmed = true
                stack.alphaValue = 0.5
                hintLabel.alphaValue = 0
            } else {
                scheduleDim()
            }
        }

        if AppSettings.showClock || AppSettings.showDate || (hasContent && motion != .off) {
            tick()
            let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in self?.tick() }
            RunLoop.main.add(timer, forMode: .common)
            clockTimer = timer
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        clockTimer?.invalidate()
        dimTimer?.invalidate()
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
        let time = DateFormatter()
        time.dateFormat = "h:mm"
        clockLabel.stringValue = time.string(from: now)
        let date = DateFormatter()
        date.dateFormat = "EEEE, MMMM d"
        dateLabel.stringValue = date.string(from: now)

        let minuteIndex = Int(wallClockMinutes.rounded(.down))
        guard minuteIndex != lastMinuteIndex else { return }
        let isFirstTick = lastMinuteIndex == -1
        lastMinuteIndex = minuteIndex
        guard !isFirstTick else { return }
        switch motion {
        case .drift:
            applyDrift(animated: true)
        case .wander:
            if minuteIndex.isMultiple(of: 15) { relocate(animated: true) }
        case .off:
            break
        }
    }

    // MARK: Drift (AOSP zigzag)

    /// Incommensurate periods in minutes, straight from AOSP's BurnInHelper —
    /// their ratio is irrational enough that the 2-D path never visibly repeats.
    private static let driftPeriodX = 83.0
    private static let driftPeriodY = 521.0
    /// Full travel per axis, clamped so tiny displays never drift the stack
    /// more than 5% of their smaller dimension.
    private var driftAmplitude: CGSize {
        let cap = min(bounds.width, bounds.height) * 0.05
        return CGSize(width: min(32, cap), height: min(48, cap))
    }

    /// Triangular wave: sweeps 0 → amplitude → 0 over one period.
    private static func zigzag(_ minutes: Double, amplitude: CGFloat, period: Double) -> CGFloat {
        let progress = minutes.truncatingRemainder(dividingBy: period) / period
        let ramp = progress <= 0.5 ? progress * 2 : (1 - progress) * 2
        return amplitude * CGFloat(ramp)
    }

    private var wallClockMinutes: Double {
        minutesOverride ?? Date().timeIntervalSince1970 / 60
    }

    private func applyDrift(animated: Bool) {
        let amplitude = driftAmplitude
        let minutes = wallClockMinutes
        // Centered on screen center: offsets span ±amplitude/2.
        let offset = CGPoint(
            x: Self.zigzag(minutes, amplitude: amplitude.width, period: Self.driftPeriodX) - amplitude.width / 2,
            y: Self.zigzag(minutes, amplitude: amplitude.height, period: Self.driftPeriodY) - amplitude.height / 2
        )
        setStackOffset(offset, animated: animated)
    }

    // MARK: Wander (DeskClock relocation)

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
        // DeskClock pattern: fade out, teleport, fade back in.
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 3.0
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            stack.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self else { return }
            self.setStackOffset(target, animated: false)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 3.0
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                self.stack.animator().alphaValue = self.isDimmed ? 0.5 : 1.0
            }
        })
    }

    private func setStackOffset(_ offset: CGPoint, animated: Bool) {
        let apply = { [self] in
            centerX?.constant = offset.x
            centerY?.constant = offset.y
        }
        guard animated else {
            apply()
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 1.0
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            context.allowsImplicitAnimation = true
            apply()
            layoutSubtreeIfNeeded()
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
