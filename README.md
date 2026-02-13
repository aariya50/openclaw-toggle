# OpenClaw Toggle

[![CI](https://github.com/aariya50/openclaw-toggle/actions/workflows/ci.yml/badge.svg)](https://github.com/aariya50/openclaw-toggle/actions/workflows/ci.yml)
![macOS 14+](https://img.shields.io/badge/macOS-14%2B-blue)
![Swift 5.9](https://img.shields.io/badge/Swift-5.9-orange)
![License: MIT](https://img.shields.io/badge/License-MIT-green)

A native macOS menu bar app that monitors and controls [OpenClaw](https://openclaw.ai) node and SSH tunnel services.

## Features

- **Menu bar status ring** — green (all running), yellow (tunnel only), dim (disconnected)
- **One-click controls** — start/stop tunnel and node services from the popover
- **Auto-detect** — scans `~/Library/LaunchAgents/` for OpenClaw plists on first launch
- **Configurable** — custom port, gateway host, service labels, plist paths, poll interval
- **Clean quit** — stops both services gracefully on exit

### v2.0 — New

- **First-run Setup Wizard** — 5-step guided setup (Welcome → Detect → Configure → Diagnostics → Finish)
- **Health Diagnostics** — check plist existence, service status, port listening, SSH gateway connectivity
- **SSH Tunnel Configuration** — gateway host, local port, service labels, plist paths
- **Auto-update via Sparkle** — check for updates from GitHub Releases
- **Launch at Login** — toggle via SMAppService (macOS 13+)

## Install

### Homebrew (recommended)

```bash
brew tap aariya50/tap
brew install openclaw-toggle
open "$(brew --prefix)/Cellar/openclaw-toggle/2.0.0/OpenClawToggle.app"
```

### GitHub Releases

Download `OpenClawToggle.app.zip` from [Releases](https://github.com/aariya50/openclaw-toggle/releases), unzip, and move to `/Applications/`.

### Build from source

```bash
git clone https://github.com/aariya50/openclaw-toggle.git
cd openclaw-toggle
./build-app.sh release
open build/OpenClawToggle.app
```

## Requirements

- macOS 14 (Sonoma) or later
- OpenClaw launchd services installed as LaunchAgents (`ai.openclaw.ssh-tunnel` and `ai.openclaw.node`)

## Configuration

Open **Preferences** (gear icon) to configure:
- **SSH Tunnel** — gateway host, local port, service label, plist path
- **Node Service** — service label, plist path
- **Polling** — status check interval
- **General** — Launch at Login, Check for Updates
- **Health Diagnostics** — verify your entire OpenClaw stack

Click **Detect Services** to auto-detect installed OpenClaw services, or use the **Setup Wizard** on first launch.

## How It Works

The app uses `launchctl` to manage launchd services and `lsof` to check tunnel port status. It hides from the Dock via `LSUIElement` and polls every 3 seconds (configurable). A watchdog LaunchAgent ensures services are stopped if the app crashes.

## Architecture

| File | Purpose |
|------|---------|
| `OpenClawToggleApp.swift` | App entry point, AppDelegate, menu bar icon, window management |
| `StatusMonitor.swift` | Polls launchd/lsof for service status, publishes to SwiftUI |
| `ServiceLifecycleManager.swift` | Bootstrap/bootout services, PID file, watchdog |
| `ServiceDetector.swift` | Scans ~/Library/LaunchAgents for OpenClaw plists |
| `AppSettings.swift` | UserDefaults-backed settings (port, labels, paths, gateway, launch at login) |
| `PopoverView.swift` | Menu bar popover UI with service controls |
| `PreferencesView.swift` | Preferences window with all configuration sections |
| `SetupWizardView.swift` | 5-step first-run setup wizard |
| `HealthDiagnosticsView.swift` | Diagnostics engine + view (plist, service, port, SSH checks) |
| `SparkleUpdater.swift` | Sparkle framework wrapper for auto-updates |
| `AboutView.swift` | About window with version info and links |

## Contributing

1. Fork → branch → `swift build` → PR
2. See [ROADMAP.md](ROADMAP.md) for planned features

## License

[MIT](LICENSE)
