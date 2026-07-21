# UX surface

Type: grilling
Status: resolved
Blocked by: 07

## Question

Decide every user-facing surface, with the spike as the concrete thing to react to:

- App presence: menu bar item (LSUIElement) vs Dock app vs both.
- Lock triggers: global hotkey (⌘⇧L default?), menu-bar click, and — given the AI-agent audience — a CLI/URL-scheme trigger so agents/scripts can lock the machine?
- Lock-screen appearance: what the overlay shows (clock? status? unlock hint? nothing?) — visual detail stays in fog until this decides direction.
- Settings: what's configurable at v1 (hotkey, sleep-prevention toggle, ...) and where it lives (SwiftUI settings window? menu only?).

## Answer

- **Presence:** menu-bar-only (`LSUIElement`, `.accessory` activation), no Dock icon. `NSStatusItem` menu: Lock Now (⌘⇧L) / Unlock, Permissions…, About, Quit.
- **Lock trigger:** global ⌘⇧L via an `NSEvent` global monitor (dependency-free; Accessibility already required), plus the menu item. (CLI/URL-scheme trigger for the agent audience noted as a strong post-v1 addition, out of v1 scope.)
- **Lock screen:** black field on every display, large live clock + date, and the hint "Press any key or click to unlock" — the "first interaction cues authentication" model, so no on-screen button is needed (buttons would be swallowed by the tap anyway).
- **Settings:** none configurable in v1 beyond the fixed hotkey; a settings surface is post-v1.
