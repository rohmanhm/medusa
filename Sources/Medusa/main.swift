import AppKit

// Medusa runs as a menu-bar accessory: no Dock icon, no main menu bar of its
// own. All lifecycle wiring lives in AppDelegate.
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

// Verification entry points (`--self-test`, `--lock-test`) exercise the lock
// machinery from the command line; the normal path runs the full app.
let delegate: NSApplicationDelegate
if let index = CommandLine.arguments.firstIndex(of: "--snapshot-settings"),
   CommandLine.arguments.indices.contains(index + 1) {
    delegate = SnapshotRunner(subject: .settings, outputDir: CommandLine.arguments[index + 1])
} else if let index = CommandLine.arguments.firstIndex(of: "--snapshot-shield"),
          CommandLine.arguments.indices.contains(index + 1) {
    delegate = SnapshotRunner(subject: .shield, outputDir: CommandLine.arguments[index + 1])
} else if let index = CommandLine.arguments.firstIndex(of: "--snapshot-lockpane"),
          CommandLine.arguments.indices.contains(index + 1) {
    delegate = SnapshotRunner(subject: .lockPane, outputDir: CommandLine.arguments[index + 1])
} else if let mode = SelfTestMode.from(CommandLine.arguments) {
    delegate = SelfTestRunner(mode: mode)
} else {
    delegate = AppDelegate()
}
app.delegate = delegate
app.run()
