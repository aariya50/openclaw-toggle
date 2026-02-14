# OpenClawToggle

A macOS menu bar app for managing OpenClaw services (SSH tunnel + node).

## Tech Stack
- Swift, SwiftUI, macOS 14+
- Sparkle for auto-updates
- SMAppService for launch-at-login
- launchctl for service management

## Architecture
- `OpenClawToggleApp.swift` — Main app, popover, windows
- `StatusMonitor.swift` — Service health polling
- `AppSettings.swift` — UserDefaults-backed preferences
- `SparkleUpdaterManager.swift` — Sparkle integration
- `ConnectionNotifier.swift` — macOS notifications on state changes
- `PopoverView.swift` — Main popover UI
- `PreferencesView.swift` — Settings window
- `SetupWizardView.swift` — First-run wizard

## Key Rules
- Keep UI minimal and macOS-native
- Use `pkill -x OpenClawToggle` NOT `pkill -f` (the -f flag kills the OpenClaw node service too)
- Build: `swift build`
- Run debug: `open .build/debug/OpenClawToggle`
- GitHub: github.com/aariya50/openclaw-toggle
- Homebrew Cask: aariya50/tap/openclaw-toggle
