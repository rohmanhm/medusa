import AppKit
import ServiceManagement

/// UserDefaults-backed preferences.
///
/// The SwiftUI settings panes bind straight to these keys with `@AppStorage`;
/// AppKit components read the typed accessors below and observe
/// `UserDefaults.didChangeNotification` when they need to react live (the
/// menu-bar shortcut label, for example). Reads hit the defaults in-memory
/// cache, so per-event lookups (the hotkey path) are free.
enum AppSettings {
    enum Keys {
        static let lockOnLaunch = "lockOnLaunch"
        static let hotKeyKeyCode = "hotKeyKeyCode"
        static let hotKeyModifiers = "hotKeyModifiers"
        static let hotKeyKeyChar = "hotKeyKeyChar"
        static let hotKeyDisplay = "hotKeyDisplay"
        static let backstopMinutes = "backstopMinutes"
        static let keepAwake = "keepAwake"
        static let showClock = "showClock"
        static let showDate = "showDate"
        static let showHint = "showHint"
        static let lockMessage = "lockMessage"
        static let shieldMotionStyle = "shieldMotionStyle"
        static let shieldDimMinutes = "shieldDimMinutes"
        /// Opt-in: idle / best-effort ⌃⌘Q engage Medusa instead of leaving the
        /// session to stock idle-lock. Never replaces loginwindow.
        static let systemLockPreemptEnabled = "systemLockPreemptEnabled"
        /// Idle seconds (as minutes in the picker) before preempt auto-locks.
        static let systemLockPreemptIdleMinutes = "systemLockPreemptIdleMinutes"
        /// One-shot race-loss warning latch; reset when the setting is re-enabled.
        static let systemLockPreemptWarned = "systemLockPreemptWarned"
        // MARK: Keep Awake
        /// Comma-separated preset durations in minutes (editable in Settings).
        static let keepAwakePresets = "keepAwakePresets"
        /// Default duration in minutes for Quick start / hotkey / start-at-launch.
        /// -1 means Indefinitely.
        static let keepAwakeDefaultMinutes = "keepAwakeDefaultMinutes"
        /// Default Awake level for new Sessions ("display" / "system").
        static let keepAwakeDefaultLevel = "keepAwakeDefaultLevel"
        static let keepAwakeGuardEnabled = "keepAwakeGuardEnabled"
        static let keepAwakeGuardThreshold = "keepAwakeGuardThreshold"
        static let keepAwakeEndedNotify = "keepAwakeEndedNotify"
        static let keepAwakeSoonNotify = "keepAwakeSoonNotify"
        static let keepAwakeSoonMinutes = "keepAwakeSoonMinutes"
        static let keepAwakeHotKeyKeyCode = "keepAwakeHotKeyKeyCode"
        static let keepAwakeHotKeyModifiers = "keepAwakeHotKeyModifiers"
        static let keepAwakeHotKeyKeyChar = "keepAwakeHotKeyKeyChar"
        static let keepAwakeHotKeyDisplay = "keepAwakeHotKeyDisplay"
        static let keepAwakeShowCountdown = "keepAwakeShowCountdown"
        static let keepAwakeStartAtLaunch = "keepAwakeStartAtLaunch"
    }

    /// Default shortcut: ⌘⇧L (keyCode 37 == "L" on the ANSI layout).
    static let defaultHotKeyKeyCode = 37
    static let defaultHotKeyModifiers = Int(bitPattern: NSEvent.ModifierFlags([.command, .shift]).rawValue)
    static let defaultHotKeyKeyChar = "l"
    static let defaultHotKeyDisplay = "⌘⇧L"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            Keys.lockOnLaunch: false,
            Keys.hotKeyKeyCode: defaultHotKeyKeyCode,
            Keys.hotKeyModifiers: defaultHotKeyModifiers,
            Keys.hotKeyKeyChar: defaultHotKeyKeyChar,
            Keys.hotKeyDisplay: defaultHotKeyDisplay,
            // 4 hours — long enough that overnight renders/agents aren't killed
            // by the fail-safe, short enough that a wedged unlock still recovers
            // without a reboot. "Never" remains available for open-ended locks.
            Keys.backstopMinutes: 240,
            Keys.keepAwake: true,
            Keys.showClock: true,
            Keys.showDate: true,
            Keys.showHint: true,
            Keys.lockMessage: "",
            Keys.shieldMotionStyle: ShieldMotionStyle.wander.rawValue,
            Keys.shieldDimMinutes: 5,
            Keys.systemLockPreemptEnabled: false,
            Keys.systemLockPreemptIdleMinutes: 5,
            Keys.systemLockPreemptWarned: false,
            Keys.keepAwakePresets: "15,30,60,120,240,480,720",
            Keys.keepAwakeDefaultMinutes: -1,
            Keys.keepAwakeDefaultLevel: AwakeLevel.display.rawValue,
            Keys.keepAwakeGuardEnabled: true,
            Keys.keepAwakeGuardThreshold: 10,
            Keys.keepAwakeEndedNotify: true,
            Keys.keepAwakeSoonNotify: false,
            Keys.keepAwakeSoonMinutes: 5,
            Keys.keepAwakeHotKeyKeyCode: 0,
            Keys.keepAwakeHotKeyModifiers: 0,
            Keys.keepAwakeHotKeyKeyChar: "",
            Keys.keepAwakeHotKeyDisplay: "None",
            Keys.keepAwakeShowCountdown: false,
            Keys.keepAwakeStartAtLaunch: false
        ])
    }

    private static var defaults: UserDefaults { .standard }

    /// Lock immediately when Medusa launches (once permissions are granted).
    static var lockOnLaunch: Bool { defaults.bool(forKey: Keys.lockOnLaunch) }

    static var hotKeyKeyCode: UInt16 { UInt16(clamping: defaults.integer(forKey: Keys.hotKeyKeyCode)) }

    static var hotKeyModifiers: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: UInt(bitPattern: defaults.integer(forKey: Keys.hotKeyModifiers)))
    }

    /// Lowercase character for `NSMenuItem.keyEquivalent`.
    static var hotKeyKeyChar: String { defaults.string(forKey: Keys.hotKeyKeyChar) ?? defaultHotKeyKeyChar }

    /// Human-readable shortcut, e.g. "⌘⇧L".
    static var hotKeyDisplay: String { defaults.string(forKey: Keys.hotKeyDisplay) ?? defaultHotKeyDisplay }

    /// The dead-man's-switch horizon. 0 disables the timer entirely — the
    /// wedge detector and fail-open paths still guarantee the lock can't trap.
    static var backstopDuration: TimeInterval {
        TimeInterval(defaults.integer(forKey: Keys.backstopMinutes) * 60)
    }

    /// Hold the keep-awake power assertion while locked.
    static var keepAwake: Bool { defaults.bool(forKey: Keys.keepAwake) }

    static var showClock: Bool { defaults.bool(forKey: Keys.showClock) }
    static var showDate: Bool { defaults.bool(forKey: Keys.showDate) }
    static var showHint: Bool { defaults.bool(forKey: Keys.showHint) }

    /// Optional note shown on the lock screen ("Back in 10 — render running").
    static var lockMessage: String { defaults.string(forKey: Keys.lockMessage) ?? "" }

    /// Burn-in protection: how the lock-screen content moves. Defaults to
    /// Wander — the strongest, and visibly obvious, positional spread — so OLED
    /// panels are protected out of the box and you can *see* it working.
    static var shieldMotion: ShieldMotionStyle {
        ShieldMotionStyle(rawValue: defaults.string(forKey: Keys.shieldMotionStyle) ?? "") ?? .wander
    }

    /// Burn-in protection: dim the lock-screen text after this long. 0 = never.
    static var shieldDimDuration: TimeInterval {
        TimeInterval(defaults.integer(forKey: Keys.shieldDimMinutes) * 60)
    }

    /// When true, idle (and best-effort ⌃⌘Q) engage Medusa before stock idle-lock.
    static var systemLockPreemptEnabled: Bool {
        defaults.bool(forKey: Keys.systemLockPreemptEnabled)
    }

    /// Idle duration before preempt auto-locks. Default 5 minutes.
    static var systemLockPreemptIdleDuration: TimeInterval {
        TimeInterval(defaults.integer(forKey: Keys.systemLockPreemptIdleMinutes) * 60)
    }

    /// Whether the user has already been told we lost a race to loginwindow.
    static var systemLockPreemptWarned: Bool {
        get { defaults.bool(forKey: Keys.systemLockPreemptWarned) }
        set { defaults.set(newValue, forKey: Keys.systemLockPreemptWarned) }
    }

    // MARK: Keep Awake

    /// Indefinite marker for `keepAwakeDefaultMinutes`.
    static let keepAwakeIndefiniteMinutes = -1

    /// Editable preset durations (minutes), parsed from a comma-separated
    /// string so `@AppStorage` can bind it directly.
    static var keepAwakePresetMinutes: [Int] {
        let raw = defaults.string(forKey: Keys.keepAwakePresets) ?? ""
        let parsed = raw.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }.filter { $0 > 0 }
        return parsed.isEmpty ? [15, 30, 60, 120, 240, 480, 720] : Array(parsed.prefix(12))
    }

    /// The End condition used by Quick start, the hotkey, and start-at-launch.
    static var keepAwakeDefaultEnd: KeepAwakeEndCondition {
        let minutes = defaults.integer(forKey: Keys.keepAwakeDefaultMinutes)
        if minutes == keepAwakeIndefiniteMinutes { return .indefinitely }
        return .duration(TimeInterval(max(1, minutes) * 60))
    }

    static var keepAwakeDefaultMinutes: Int { defaults.integer(forKey: Keys.keepAwakeDefaultMinutes) }

    static var keepAwakeDefaultLevel: AwakeLevel {
        AwakeLevel(rawValue: defaults.string(forKey: Keys.keepAwakeDefaultLevel) ?? "") ?? .display
    }

    static var keepAwakeGuardEnabled: Bool { defaults.bool(forKey: Keys.keepAwakeGuardEnabled) }
    static var keepAwakeGuardThreshold: Int { defaults.integer(forKey: Keys.keepAwakeGuardThreshold) }
    static var keepAwakeEndedNotify: Bool { defaults.bool(forKey: Keys.keepAwakeEndedNotify) }
    static var keepAwakeSoonNotify: Bool { defaults.bool(forKey: Keys.keepAwakeSoonNotify) }
    static var keepAwakeSoonMinutes: Int { defaults.integer(forKey: Keys.keepAwakeSoonMinutes) }
    static var keepAwakeShowCountdown: Bool { defaults.bool(forKey: Keys.keepAwakeShowCountdown) }
    static var keepAwakeStartAtLaunch: Bool { defaults.bool(forKey: Keys.keepAwakeStartAtLaunch) }

    static var keepAwakeHotKeyKeyCode: UInt16 { UInt16(clamping: defaults.integer(forKey: Keys.keepAwakeHotKeyKeyCode)) }

    static var keepAwakeHotKeyModifiers: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: UInt(bitPattern: defaults.integer(forKey: Keys.keepAwakeHotKeyModifiers)))
    }

    static var keepAwakeHotKeyAssigned: Bool {
        defaults.integer(forKey: Keys.keepAwakeHotKeyKeyCode) != 0
            && defaults.integer(forKey: Keys.keepAwakeHotKeyModifiers) != 0
    }
}

/// How the lock-screen content stack moves to spread OLED wear.
enum ShieldMotionStyle: String {
    /// AOSP-style incommensurate zigzag driven by a display link off the wall
    /// clock, via a layer transform across the full usable screen — gliding
    /// the instant the shield appears, at the panel's native refresh rate.
    case drift
    /// DeskClock-style relocation to a random point every couple of minutes,
    /// with a fade-teleport-fade (plus a first relocate ~1.5 s after lock so
    /// the protection is obvious immediately). The strongest positional spread.
    case wander
    /// Static center, today's pre-protection behavior.
    case off
}

/// Launch-at-login via `SMAppService`. The service is the source of truth (not
/// UserDefaults) — the system owns this state and the user can flip it in
/// System Settings › General › Login Items behind our back.
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// Returns nil on success, or a human-readable failure (the common one:
    /// running unbundled via `swift run`, where there is no .app to register).
    static func setEnabled(_ enabled: Bool) -> String? {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
