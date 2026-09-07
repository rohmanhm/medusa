import SwiftUI
import AppKit

/// A compact "click, then type" shortcut recorder.
///
/// While recording, a local event monitor swallows the next key press and
/// stores it as a global shortcut. Escape cancels; a shortcut must include
/// ⌘, ⌃, or ⌥ so plain typing can never trigger an action.
struct ShortcutRecorder: View {
    /// Which chord this recorder edits. The lock chord ships as ⌘⇧L; the
    /// keep-awake chord ships unassigned (this audience's app chords are
    /// sacred) — resetting it clears back to None.
    struct KeySet {
        let codeKey: String
        let modifiersKey: String
        let charKey: String
        let displayKey: String
        let defaultCode: Int
        let defaultModifiers: Int
        let defaultChar: String
        let defaultDisplay: String

        static let lock = KeySet(
            codeKey: AppSettings.Keys.hotKeyKeyCode,
            modifiersKey: AppSettings.Keys.hotKeyModifiers,
            charKey: AppSettings.Keys.hotKeyKeyChar,
            displayKey: AppSettings.Keys.hotKeyDisplay,
            defaultCode: AppSettings.defaultHotKeyKeyCode,
            defaultModifiers: AppSettings.defaultHotKeyModifiers,
            defaultChar: AppSettings.defaultHotKeyKeyChar,
            defaultDisplay: AppSettings.defaultHotKeyDisplay
        )

        static let keepAwake = KeySet(
            codeKey: AppSettings.Keys.keepAwakeHotKeyKeyCode,
            modifiersKey: AppSettings.Keys.keepAwakeHotKeyModifiers,
            charKey: AppSettings.Keys.keepAwakeHotKeyKeyChar,
            displayKey: AppSettings.Keys.keepAwakeHotKeyDisplay,
            defaultCode: 0,
            defaultModifiers: 0,
            defaultChar: "",
            defaultDisplay: "None"
        )
    }

    let keys: KeySet

    init(keys: KeySet = .lock) {
        self.keys = keys
    }

    @State private var display = ""

    @State private var isRecording = false
    @State private var monitor: Any?

    private var isDefault: Bool {
        UserDefaults.standard.integer(forKey: keys.codeKey) == keys.defaultCode
            && UserDefaults.standard.integer(forKey: keys.modifiersKey) == keys.defaultModifiers
    }

    var body: some View {
        HStack(spacing: 6) {
            if !isDefault && !isRecording {
                Button {
                    save(
                        keyCode: keys.defaultCode,
                        modifiers: keys.defaultModifiers,
                        keyChar: keys.defaultChar,
                        display: keys.defaultDisplay
                    )
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .buttonStyle(.borderless)
                .help("Reset to \(keys.defaultDisplay)")
            }

            Button(action: toggleRecording) {
                Text(isRecording ? "Type shortcut…" : display)
                    .font(isRecording ? .body : .body.monospaced())
                    .foregroundStyle(isRecording ? Color.secondary : Color.primary)
                    .frame(minWidth: 76)
            }
        }
        .onAppear {
            let saved = UserDefaults.standard.string(forKey: keys.displayKey)
            display = (saved?.isEmpty ?? true) ? keys.defaultDisplay : (saved ?? keys.defaultDisplay)
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
        defaults.set(keyCode, forKey: keys.codeKey)
        defaults.set(modifiers, forKey: keys.modifiersKey)
        defaults.set(keyChar, forKey: keys.charKey)
        defaults.set(display, forKey: keys.displayKey)
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
