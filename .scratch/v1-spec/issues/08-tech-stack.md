# Tech stack & minimum macOS version

Type: grilling
Status: resolved
Blocked by: 07

## Question

Lock the build foundations, informed by the spike:

- Swift version; SwiftUI vs AppKit vs hybrid (AppKit for tap/overlay windows, SwiftUI for settings) — what did the spike suggest?
- Minimum macOS version: require 15+, or support 13/14 for wider reach? Which APIs from research tickets gate this?
- Project layout: SPM-only vs `.xcodeproj`; impacts CI and contributor experience.
- Dependency policy: zero-dependency vs allowing e.g. Sparkle, a hotkey library.

## Answer

Swift 5 language mode (via `swiftLanguageModes: [.v5]`, tools-version 6.0) to avoid Swift 6 strict-concurrency friction with the C event-tap callback. **Pure AppKit**, no SwiftUI, **zero third-party dependencies**. SPM `executableTarget` built to a binary, then assembled into an ad-hoc-signed `.app` by `scripts/build-app.sh` (no `.xcodeproj` — CLI-reproducible, contributor-friendly). Minimum macOS 13, developed/tested on 26.5. Sparkle (updates) is deferred to the distribution work rather than pulled in now.
