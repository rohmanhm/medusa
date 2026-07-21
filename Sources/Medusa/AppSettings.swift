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
            Keys.backstopMinutes: 30,
            Keys.keepAwake: true,
            Keys.showClock: true,
            Keys.showDate: true,
            Keys.showHint: true,
            Keys.lockMessage: "",
            Keys.shieldMotionStyle: ShieldMotionStyle.drift.rawValue,
            Keys.shieldDimMinutes: 10
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

    /// Burn-in protection: how the lock-screen content moves. Defaults to the
    /// sub-perceptual drift so OLED panels are safe out of the box.
    static var shieldMotion: ShieldMotionStyle {
        ShieldMotionStyle(rawValue: defaults.string(forKey: Keys.shieldMotionStyle) ?? "") ?? .drift
    }

    /// Burn-in protection: dim the lock-screen text after this long. 0 = never.
    static var shieldDimDuration: TimeInterval {
        TimeInterval(defaults.integer(forKey: Keys.shieldDimMinutes) * 60)
    }
}

/// How the lock-screen content stack moves to spread OLED wear.
enum ShieldMotionStyle: String {
    /// AOSP-style zigzag of the center constraints — invisible in practice.
    case drift
    /// DeskClock-style relocation to a random point every 15 minutes.
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
