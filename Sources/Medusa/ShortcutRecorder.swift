import SwiftUI
import AppKit

/// A compact "click, then type" shortcut recorder.
///
/// While recording, a local event monitor swallows the next key press and
/// stores it as the global lock shortcut. Escape cancels; a shortcut must
/// include ⌘, ⌃, or ⌥ so plain typing can never trigger a lock.
struct ShortcutRecorder: View {
    @AppStorage(AppSettings.Keys.hotKeyDisplay) private var display = AppSettings.defaultHotKeyDisplay

    @State private var isRecording = false
    @State private var monitor: Any?

    private var isDefault: Bool {
        UserDefaults.standard.integer(forKey: AppSettings.Keys.hotKeyKeyCode) == AppSettings.defaultHotKeyKeyCode
            && UserDefaults.standard.integer(forKey: AppSettings.Keys.hotKeyModifiers) == AppSettings.defaultHotKeyModifiers
    }

    var body: some View {
        HStack(spacing: 6) {
            if !isDefault && !isRecording {
                Button {
                    save(
                        keyCode: AppSettings.defaultHotKeyKeyCode,
                        modifiers: AppSettings.defaultHotKeyModifiers,
                        keyChar: AppSettings.defaultHotKeyKeyChar,
                        display: AppSettings.defaultHotKeyDisplay
                    )
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .buttonStyle(.borderless)
                .help("Reset to \(AppSettings.defaultHotKeyDisplay)")
            }

            Button(action: toggleRecording) {
                Text(isRecording ? "Type shortcut…" : display)
                    .font(isRecording ? .body : .body.monospaced())
                    .foregroundStyle(isRecording ? Color.secondary : Color.primary)
                    .frame(minWidth: 76)
            }
        }
        .onDisappear(perform: stopRecording)
    }

    private func toggleRecording() {
        isRecording ? stopRecording() : startRecording()
    }

    private func startRecording() {
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handle(event)
            return nil // swallow while recording
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isRecording = false
    }

    private func handle(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        if event.keyCode == 53 && flags.isEmpty { // Escape — cancel
            stopRecording()
            return
        }

        // Demand a real chord: plain keys (or shift alone) would make everyday
        // typing lock the machine.
        guard !flags.intersection([.command, .control, .option]).isEmpty else {
            NSSound.beep()
            return
        }

        guard let key = Self.keyName(for: event) else {
            NSSound.beep()
            return
        }

        save(
            keyCode: Int(event.keyCode),
            modifiers: Int(bitPattern: flags.rawValue),
            keyChar: event.charactersIgnoringModifiers?.lowercased() ?? "",
            display: Self.symbols(for: flags) + key
        )
        stopRecording()
    }

    private func save(keyCode: Int, modifiers: Int, keyChar: String, display: String) {
        let defaults = UserDefaults.standard
        defaults.set(keyCode, forKey: AppSettings.Keys.hotKeyKeyCode)
        defaults.set(modifiers, forKey: AppSettings.Keys.hotKeyModifiers)
        defaults.set(keyChar, forKey: AppSettings.Keys.hotKeyKeyChar)
        defaults.set(display, forKey: AppSettings.Keys.hotKeyDisplay)
        self.display = display
    }

    private static func symbols(for flags: NSEvent.ModifierFlags) -> String {
        var out = ""
        if flags.contains(.control) { out += "⌃" }
        if flags.contains(.option) { out += "⌥" }
        if flags.contains(.shift) { out += "⇧" }
        if flags.contains(.command) { out += "⌘" }
        return out
    }

    private static let specialKeys: [UInt16: String] = [
        36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 76: "⌤", 117: "⌦",
        115: "↖", 119: "↘", 116: "⇞", 121: "⇟",
        123: "←", 124: "→", 125: "↓", 126: "↑"
    ]

    private static func keyName(for event: NSEvent) -> String? {
        if let special = specialKeys[event.keyCode] { return special }
        guard let chars = event.charactersIgnoringModifiers, !chars.isEmpty else { return nil }
        return chars.uppercased()
    }
}
