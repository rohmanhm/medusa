import SwiftUI

// MARK: - General

struct GeneralPane: View {
    @AppStorage(AppSettings.Keys.lockOnLaunch) private var lockOnLaunch = false
    @AppStorage(AppSettings.Keys.backstopMinutes) private var backstopMinutes = 30

    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var loginItemError: String?

    private static let backstopChoices: [(minutes: Int, label: String)] = [
        (15, "15 minutes"),
        (30, "30 minutes"),
        (60, "1 hour"),
        (120, "2 hours"),
        (240, "4 hours"),
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
                Text("However badly an unlock goes, Medusa releases the lock by itself "
                    + "after this long. Touch ID normally unlocks in seconds — this is "
                    + "the dead-man's switch, not something you should ever notice.")
            }
        }
        .formStyle(.grouped)
        .frame(width: 590, height: 440)
    }
}

// MARK: - Lock Screen

struct LockScreenPane: View {
    @AppStorage(AppSettings.Keys.showClock) private var showClock = true
    @AppStorage(AppSettings.Keys.showDate) private var showDate = true
    @AppStorage(AppSettings.Keys.showHint) private var showHint = true
    @AppStorage(AppSettings.Keys.lockMessage) private var lockMessage = ""
    @AppStorage(AppSettings.Keys.keepAwake) private var keepAwake = true

    var body: some View {
        Form {
            Section {
                LockScreenPreview(
                    showClock: showClock,
                    showDate: showDate,
                    showHint: showHint,
                    message: lockMessage
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
                Toggle("Keep Mac awake while locked", isOn: $keepAwake)
            } footer: {
                Text("Holds a power assertion so long builds, renders, and agents keep "
                    + "running under the shield. Turn off to let the display sleep on "
                    + "its normal schedule.")
            }
        }
        .formStyle(.grouped)
        .frame(width: 590, height: 645)
    }
}

/// A miniature, live rendition of the shield so toggles can be judged without
/// actually locking the machine.
private struct LockScreenPreview: View {
    let showClock: Bool
    let showDate: Bool
    let showHint: Bool
    let message: String

    var body: some View {
        TimelineView(.everyMinute) { context in
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
                        .padding(.top, 8)
                }
                if !showClock && !showDate && !showHint && message.isEmpty {
                    Text("Just black. Very Medusa.")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.3))
                }
            }
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity, minHeight: 150)
            .background(.black)
        }
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
