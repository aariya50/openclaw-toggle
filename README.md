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
- **Configurable** — custom port, service labels, plist paths, poll interval
- **Clean quit** — stops both services gracefully on exit

## Install

### Homebrew (recommended)

```bash
brew tap aariya50/tap
brew install openclaw-toggle
open "$(brew --prefix)/Cellar/openclaw-toggle/1.0.0/OpenClawToggle.app"
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

Open **Preferences** (gear icon) to configure tunnel port, service labels, plist paths, and poll interval. Click **Scan** to auto-detect installed OpenClaw services.

## How It Works

The app uses `launchctl` to manage launchd services and `lsof` to check tunnel port status. It hides from the Dock via `LSUIElement` and polls every 3 seconds (configurable).

## Contributing

1. Fork → branch → `swift build` → PR
2. See [ROADMAP.md](ROADMAP.md) for planned features

## License

[MIT](LICENSE)
