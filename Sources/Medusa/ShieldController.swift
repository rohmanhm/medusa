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
    /// back to full shielding once auth ends.
    func setAuthMode(_ authenticating: Bool) {
        let level = authenticating ? authLevel : lockedLevel
        for window in windows { window.level = level }
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
final class ShieldContentView: NSView {
    private let clockLabel = ShieldContentView.makeLabel(size: 84, weight: .thin, alpha: 0.95)
    private let dateLabel = ShieldContentView.makeLabel(size: 17, weight: .regular, alpha: 0.5)
    private let messageLabel = ShieldContentView.makeLabel(size: 16, weight: .regular, alpha: 0.75)
    private let hintLabel = ShieldContentView.makeLabel(size: 15, weight: .medium, alpha: 0.6)
    private var clockTimer: Timer?

    override init(frame frameRect: NSRect) {
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

        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])

        if AppSettings.showClock || AppSettings.showDate {
            tick()
            let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in self?.tick() }
            RunLoop.main.add(timer, forMode: .common)
            clockTimer = timer
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { clockTimer?.invalidate() }

    private func tick() {
        let now = Date()
        let time = DateFormatter()
        time.dateFormat = "h:mm"
        clockLabel.stringValue = time.string(from: now)
        let date = DateFormatter()
        date.dateFormat = "EEEE, MMMM d"
        dateLabel.stringValue = date.string(from: now)
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
