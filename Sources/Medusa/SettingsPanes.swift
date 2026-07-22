import Sparkle
import SwiftUI

// MARK: - General

struct GeneralPane: View {
    var updater: UpdaterController?

    @AppStorage(AppSettings.Keys.lockOnLaunch) private var lockOnLaunch = false
    @AppStorage(AppSettings.Keys.backstopMinutes) private var backstopMinutes = 240

    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var loginItemError: String?

    private static let backstopChoices: [(minutes: Int, label: String)] = [
        (240, "4 hours"),
        (120, "2 hours"),
        (60, "1 hour"),
        (30, "30 minutes"),
        (15, "15 minutes"),
        (0, "Never")
    ]

    var body: some View {
        Form {
            Section {
                Toggle("Launch Medusa at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { enabled in
                        guard enabled != LoginItem.isEnabled else { return }
                        if let failure = LoginItem.setEnabled(enabled) {
                            loginItemError = failure
                            launchAtLogin = LoginItem.isEnabled
                        } else {
                            loginItemError = nil
                        }
                    }
                Toggle("Lock as soon as Medusa starts", isOn: $lockOnLaunch)
            } header: {
                Text("Startup")
            } footer: {
                if let loginItemError {
                    Text("Couldn't update the login item: \(loginItemError)")
                        .foregroundStyle(.red)
                }
            }

            Section {
                LabeledContent("Lock or unlock") { ShortcutRecorder() }
            } header: {
                Text("Keyboard Shortcut")
            } footer: {
                Text("Works from any app. Click the shortcut, then type a new key combination.")
            }

            Section {
                Picker("Fail-safe auto-unlock", selection: $backstopMinutes) {
                    ForEach(Self.backstopChoices, id: \.minutes) { choice in
                        Text(choice.label).tag(choice.minutes)
                    }
                }
            } header: {
                Text("Safety")
            } footer: {
                Text("Dead-man's switch: if unlock ever wedges, Medusa releases itself "
                    + "after this long so you're never trapped. Defaults to 4 hours so "
                    + "overnight locks aren't cut short — pick Never for open-ended "
                    + "sessions. Touch ID still unlocks in seconds under normal use.")
            }

            Section {
                if let updater, UpdaterController.updatesSupported {
                    UpdatesRows(updater: updater)
                } else {
                    LabeledContent("Version", value: Self.versionString)
                    Text("Automatic updates are available in released builds only.")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Updates")
            }
        }
        .formStyle(.grouped)
        .frame(width: 590, height: 560)
    }

    static var versionString: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(short) (\(build))"
    }
}

/// The live rows of the Updates section — separate so the KVO-backed model
/// only exists when the updater actually runs.
private struct UpdatesRows: View {
    @StateObject private var model: UpdaterViewModel

    init(updater: UpdaterController) {
        _model = StateObject(wrappedValue: UpdaterViewModel(updater: updater.updater))
    }

    var body: some View {
        Toggle("Check for updates automatically", isOn: $model.autoChecks)
        LabeledContent("Version", value: GeneralPane.versionString)
        LabeledContent(model.lastCheckedLabel) {
            Button("Check Now") { model.checkNow() }
                .disabled(!model.canCheck)
        }
    }
}

/// Bridges SPUUpdater's KVO properties into SwiftUI.
private final class UpdaterViewModel: ObservableObject {
    private let updater: SPUUpdater
    private var observers: [NSKeyValueObservation] = []

    @Published private(set) var canCheck: Bool
    @Published var autoChecks: Bool {
        didSet {
            if updater.automaticallyChecksForUpdates != autoChecks {
                updater.automaticallyChecksForUpdates = autoChecks
            }
        }
    }

    init(updater: SPUUpdater) {
        self.updater = updater
        canCheck = updater.canCheckForUpdates
        autoChecks = updater.automaticallyChecksForUpdates
        observers.append(updater.observe(\.canCheckForUpdates) { [weak self] updater, _ in
            DispatchQueue.main.async { self?.canCheck = updater.canCheckForUpdates }
        })
        observers.append(updater.observe(\.automaticallyChecksForUpdates) { [weak self] updater, _ in
            DispatchQueue.main.async { self?.autoChecks = updater.automaticallyChecksForUpdates }
        })
    }

    var lastCheckedLabel: String {
        guard let date = updater.lastUpdateCheckDate else { return "Never checked" }
        return "Last checked \(date.formatted(.relative(presentation: .named)))"
    }

    func checkNow() {
        updater.checkForUpdates()
    }
}

// MARK: - Lock Screen

struct LockScreenPane: View {
    @AppStorage(AppSettings.Keys.showClock) private var showClock = true
    @AppStorage(AppSettings.Keys.showDate) private var showDate = true
    @AppStorage(AppSettings.Keys.showHint) private var showHint = true
    @AppStorage(AppSettings.Keys.lockMessage) private var lockMessage = ""
    @AppStorage(AppSettings.Keys.keepAwake) private var keepAwake = true
    @AppStorage(AppSettings.Keys.shieldMotionStyle) private var motionStyle = ShieldMotionStyle.wander.rawValue
    @AppStorage(AppSettings.Keys.shieldDimMinutes) private var dimMinutes = 5

    private static let motionChoices: [(style: ShieldMotionStyle, label: String)] = [
        (.wander, "Wander"),
        (.drift, "Gentle drift"),
        (.off, "Off")
    ]

    private static let dimChoices: [(minutes: Int, label: String)] = [
        (2, "2 minutes"),
        (5, "5 minutes"),
        (10, "10 minutes"),
        (15, "15 minutes"),
        (30, "30 minutes"),
        (0, "Never")
    ]

    var body: some View {
        Form {
            Section {
                LockScreenPreview(
                    showClock: showClock,
                    showDate: showDate,
                    showHint: showHint,
                    message: lockMessage,
                    motion: ShieldMotionStyle(rawValue: motionStyle) ?? .wander,
                    dimEnabled: dimMinutes > 0
                )
                .listRowInsets(EdgeInsets())
            }

            Section("Appearance") {
                Toggle("Show clock", isOn: $showClock)
                Toggle("Show date", isOn: $showDate)
                Toggle("Show unlock hint", isOn: $showHint)
            }

            Section {
                TextField("Message", text: $lockMessage, prompt: Text("None"), axis: .vertical)
                    .lineLimit(1...3)
                    .labelsHidden()
            } header: {
                Text("Message")
            } footer: {
                Text("Shown to anyone who walks up to the locked screen — "
                    + "\u{201C}Back in 10, render in progress\u{201D} and the like.")
            }

            Section {
                Picker("Motion", selection: $motionStyle) {
                    ForEach(Self.motionChoices, id: \.style.rawValue) { choice in
                        Text(choice.label).tag(choice.style.rawValue)
                    }
                }
                Picker("Dim after", selection: $dimMinutes) {
                    ForEach(Self.dimChoices, id: \.minutes) { choice in
                        Text(choice.label).tag(choice.minutes)
                    }
                }
            } header: {
                Text("Screen Protection")
            } footer: {
                Text("Keeps long locks kind to OLED displays. Wander jumps the clock "
                    + "to a new spot every couple of minutes; Gentle drift glides it "
                    + "smoothly across the whole screen from the moment you lock; "
                    + "dimming fades it once you've stepped away. On lock, a brief "
                    + "note confirms what's on. Changes apply from the next lock.")
            }

            Section {
                Toggle("Keep Mac awake while locked", isOn: $keepAwake)
            } footer: {
                Text("Holds a power assertion so long builds, renders, and agents keep "
                    + "running under the shield. Turn off to let the display sleep on "
                    + "its normal schedule.")
            }
        }
        .formStyle(.grouped)
        .frame(width: 590, height: 780)
    }
}

/// A miniature, live rendition of the shield so toggles can be judged without
/// actually locking the machine.
///
/// The burn-in protection is demoed sped-up: the real drift moves under a
/// point a minute and dimming waits minutes of idle — invisible in a preview —
/// so here drift sweeps its wander box in seconds, Wander relocates every few
/// seconds with the real fade-teleport-fade choreography, and the dim cycle
/// dims and recovers every few seconds. A caption marks the acceleration.
private struct LockScreenPreview: View {
    let showClock: Bool
    let showDate: Bool
    let showHint: Bool
    let message: String
    let motion: ShieldMotionStyle
    let dimEnabled: Bool

    private var hasContent: Bool { showClock || showDate || showHint || !message.isEmpty }
    private var demoActive: Bool { hasContent && (motion != .off || dimEnabled) }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let demo = Self.demo(
                at: context.date.timeIntervalSinceReferenceDate,
                motion: motion,
                dimEnabled: dimEnabled
            )
            ZStack(alignment: .bottomTrailing) {
                VStack(spacing: 3) {
                    if showClock {
                        Text(Self.time.string(from: context.date))
                            .font(.system(size: 36, weight: .thin))
                            .foregroundStyle(.white.opacity(0.95))
                    }
                    if showDate {
                        Text(Self.date.string(from: context.date))
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                    if !message.isEmpty {
                        Text(message)
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.75))
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .padding(.top, 8)
                    }
                    if showHint {
                        Text("Press any key or click to unlock")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.white.opacity(0.6))
                            .opacity(demo.hintOpacity)
                            .animation(.easeInOut(duration: 0.55), value: demo.hintOpacity)
                            .padding(.top, 8)
                    }
                    if !hasContent {
                        Text("Just black. Very Medusa.")
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.3))
                    }
                }
                .opacity(demo.stackOpacity)
                .animation(.easeInOut(duration: 0.55), value: demo.stackOpacity)
                .offset(demo.offset)
                // Wander teleports while faded out, exactly like the shield;
                // drift glides between minute steps.
                .animation(motion == .drift ? .easeInOut(duration: 0.9) : nil, value: demo.offset)
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity, minHeight: 150)

                if demoActive {
                    Text("Sped-up demo")
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.25))
                        .padding(6)
                }
            }
            .background(.black)
            .clipped()
        }
    }

    /// The accelerated demo state for one timeline tick. Pure function of the
    /// wall clock so it needs no state and every tick is deterministic.
    private static func demo(at t: TimeInterval, motion: ShieldMotionStyle, dimEnabled: Bool) -> DemoState {
        var demo = DemoState()

        // Dim cycle: 12 s period — bright for 6 s, dimmed (stack ×0.5, hint
        // hidden) for 5.5 s, then the fast recovery.
        if dimEnabled {
            let phase = t.truncatingRemainder(dividingBy: 12)
            if phase >= 6 && phase < 11.5 {
                demo.stackOpacity = 0.5
                demo.hintOpacity = 0
            }
        }

        switch motion {
        case .drift:
            // The real zigzag with seconds standing in for minutes: the
            // 83/521-minute periods become 9/13-second sweeps of a preview-
            // scaled wander box.
            demo.offset = CGSize(
                width: zigzag(t, amplitude: 44, period: 9) - 22,
                height: zigzag(t, amplitude: 28, period: 13) - 14
            )
        case .wander:
            // Relocate every 4 s: fade out for the last half-second of a slot,
            // snap to the next slot's position while invisible, fade back in.
            let slot = Int((t / 4).rounded(.down))
            let phase = t - Double(slot) * 4
            if phase >= 3.4 { demo.stackOpacity = 0 }
            demo.offset = CGSize(
                width: (pseudoRandom(slot * 2 + 1) * 2 - 1) * 70,
                height: (pseudoRandom(slot * 2) * 2 - 1) * 26
            )
        case .off:
            break
        }
        return demo
    }

    private struct DemoState: Equatable {
        var offset: CGSize = .zero
        var stackOpacity: Double = 1
        var hintOpacity: Double = 1
    }

    /// Same triangular wave the shield uses, in preview time.
    private static func zigzag(_ t: Double, amplitude: Double, period: Double) -> Double {
        let progress = t.truncatingRemainder(dividingBy: period) / period
        let ramp = progress <= 0.5 ? progress * 2 : (1 - progress) * 2
        return amplitude * ramp
    }

    /// Deterministic hash-noise in 0..<1 so wander positions are stable per slot.
    private static func pseudoRandom(_ seed: Int) -> Double {
        let x = sin(Double(seed) * 12.9898) * 43758.5453
        return x - x.rounded(.down)
    }

    private static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm"
        return formatter
    }()

    private static let date: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, MMMM d"
        return formatter
    }()
}

// MARK: - Permissions

struct PermissionsPane: View {
    @State private var accessibility = Permissions.hasAccessibility()
    @State private var inputMonitoring = Permissions.hasInputMonitoring()

    private let poll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var allGranted: Bool { accessibility && inputMonitoring }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 56, height: 56)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(allGranted ? "Medusa is ready" : "Medusa needs two permissions")
                            .font(.headline)
                        Text(allGranted
                            ? "Press \(AppSettings.hotKeyDisplay) anytime to freeze keyboard and mouse."
                            : "Medusa freezes all input until you unlock with Touch ID or your "
                            + "password. macOS requires your explicit consent before any app can do this.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, 4)
            }

            Section {
                PermissionRow(
                    title: "Accessibility",
                    detail: "Lets Medusa block keyboard and mouse events.",
                    granted: accessibility
                ) {
                    Permissions.promptAccessibility()
                    Permissions.openAccessibilitySettings()
                }
                PermissionRow(
                    title: "Input Monitoring",
                    detail: "Lets Medusa observe the input stream it blocks.",
                    granted: inputMonitoring
                ) {
                    Permissions.promptInputMonitoring()
                    Permissions.openInputMonitoringSettings()
                }
            } footer: {
                if !allGranted {
                    Text("If Medusa is already listed in System Settings, flip its toggle on. "
                        + "This pane updates by itself the moment both are granted.")
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 590, height: 370)
        .onReceive(poll) { _ in
            accessibility = Permissions.hasAccessibility()
            inputMonitoring = Permissions.hasInputMonitoring()
        }
    }
}

private struct PermissionRow: View {
    let title: String
    let detail: String
    let granted: Bool
    let open: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle.dashed")
                .font(.system(size: 22))
                .foregroundStyle(granted ? Color.green : Color.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.body.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if granted {
                Text("Granted")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Button("Open Settings…", action: open)
            }
        }
        .padding(.vertical, 3)
    }
}
