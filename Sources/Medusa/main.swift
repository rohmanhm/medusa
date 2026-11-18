import AppKit

// Medusa runs as a menu-bar accessory: no Dock icon, no main menu bar of its
// own. All lifecycle wiring lives in AppDelegate.
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

// Verification entry points (`--self-test`, `--lock-test`, `--snapshot-*`)
// exercise the app from the command line; the normal path runs the full app.
let arguments = CommandLine.arguments
let snapshotFlags: [(flag: String, subject: SnapshotRunner.Subject)] = [
    ("--snapshot-settings", .settings),
    ("--snapshot-shield", .shield),
    ("--snapshot-lockpane", .lockPane),
    ("--snapshot-keepawakepane", .keepAwakePane),
    ("--snapshot-schedulepane", .schedulePane),
    ("--snapshot-permissionspane", .permissionsPane)
]
let snapshot = snapshotFlags.lazy.compactMap { entry -> SnapshotRunner? in
    guard let index = arguments.firstIndex(of: entry.flag), arguments.indices.contains(index + 1) else { return nil }
    return SnapshotRunner(subject: entry.subject, outputDir: arguments[index + 1])
}.first

let delegate: NSApplicationDelegate
if let snapshot {
    delegate = snapshot
} else if let index = CommandLine.arguments.firstIndex(of: "--motion-probe") {
    let next = CommandLine.arguments.index(after: index)
    let seconds = (next < CommandLine.arguments.endIndex
        ? TimeInterval(CommandLine.arguments[next])
        : nil) ?? 8
    delegate = SnapshotRunner(subject: .motionProbe(seconds: seconds))
} else if let mode = SelfTestMode.from(CommandLine.arguments) {
    delegate = SelfTestRunner(mode: mode)
} else {
    delegate = AppDelegate()
}
app.delegate = delegate
app.run()
