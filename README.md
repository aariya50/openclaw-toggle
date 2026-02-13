# OpenClaw Toggle

A lightweight, native macOS menu bar app that monitors and controls [OpenClaw](https://openclaw.ai) node and SSH tunnel services.

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-blue)
![Swift 5.9](https://img.shields.io/badge/Swift-5.9-orange)
![License: MIT](https://img.shields.io/badge/License-MIT-green)

---

## What It Does

OpenClaw Toggle sits in your menu bar and gives you at-a-glance status of your OpenClaw stack:

| Icon | Meaning |
|------|---------|
| 🟢 Green ring | SSH tunnel **and** node service are running |
| 🟡 Yellow ring | SSH tunnel active, but node service is stopped |
| ⚫ Dimmed (no ring) | Neither tunnel nor node is running |

Click the icon to see:

- **Status headline** — "Connected", "Tunnel Only", or "Disconnected"
- **SSH Tunnel row** — status dot + Start/Stop button
- **Node Service row** — status dot + Start/Stop button (disabled when tunnel is down)
- **Preferences** — gear icon opens the settings panel
- **About** — info icon shows version and links
- **Quit** — shuts down both services cleanly before exiting

Status is polled every 3 seconds (configurable in Preferences).

---

## Screenshots

> _Coming soon — the app uses a custom Alfred-inspired circular avatar icon with an Instagram Close Friends–style status ring._

---

## Requirements

- **macOS 14 (Sonoma)** or later
- **Swift 5.9+** / Xcode 15+ (for building from source)
- An existing SSH tunnel forwarding to a local port (default: `18789`)
- OpenClaw launchd services installed as LaunchAgents:
  - `~/Library/LaunchAgents/ai.openclaw.ssh-tunnel.plist`
  - `~/Library/LaunchAgents/ai.openclaw.node.plist`

> **Don't have these?** The app auto-detects OpenClaw plists on first launch. If none are found, Preferences opens automatically so you can configure paths manually.

---

## Installation

### Option A: Homebrew (recommended)

```bash
brew tap aariya50/tap
brew install openclaw-toggle
```

Then launch:

```bash
open $(brew --prefix)/Cellar/openclaw-toggle/1.0.0/OpenClawToggle.app
```

Optionally symlink to `/Applications/`:

```bash
ln -sf $(brew --prefix)/Cellar/openclaw-toggle/1.0.0/OpenClawToggle.app /Applications/OpenClawToggle.app
```

### Option B: Download from GitHub Releases

1. Download `OpenClawToggle.app.zip` from the [Releases](https://github.com/aariya50/openclaw-toggle/releases) page
2. Unzip and move `OpenClawToggle.app` to `/Applications/`
3. Right-click → Open → Open (to bypass Gatekeeper on first launch)

### Option C: Build from source

```bash
git clone https://github.com/aariya50/openclaw-toggle.git
cd openclaw-toggle

# Build the .app bundle (release)
./build-app.sh release

# Run it
open build/OpenClawToggle.app

# Or install to Applications
cp -r build/OpenClawToggle.app /Applications/
```

### Option D: Run without bundling

```bash
swift build
.build/debug/OpenClawToggle
```

> Note: When running unbundled, the icon loads from `~/Projects/OpenClawToggle/Resources/` as a fallback.

---

## How It Works

| Component | Detail |
|-----------|--------|
| **Tunnel check** | `lsof -iTCP:<port> -sTCP:LISTEN` — is something listening? |
| **Tunnel service** | `launchctl print gui/<uid>/<label>` — is the launchd service running? |
| **Node check** | `launchctl print gui/<uid>/<label>` — parses for `state = running` or live PID |
| **Start service** | `launchctl bootstrap gui/<uid> <plist-path>` |
| **Stop service** | `launchctl bootout gui/<uid>/<label>` |
| **On quit** | Bootout both services cleanly before exit |

The app hides from the Dock via `LSUIElement = true` in Info.plist and `NSApp.setActivationPolicy(.accessory)`.

---

## Configuration

Open **Preferences** (gear icon in the popover) to configure:

| Setting | Default | Description |
|---------|---------|-------------|
| Tunnel Port | `18789` | Local port the SSH tunnel forwards to |
| Tunnel Service Label | `ai.openclaw.ssh-tunnel` | launchd label for the tunnel |
| Tunnel Plist Path | `~/Library/LaunchAgents/ai.openclaw.ssh-tunnel.plist` | Path to tunnel plist |
| Node Service Label | `ai.openclaw.node` | launchd label for the node |
| Node Plist Path | `~/Library/LaunchAgents/ai.openclaw.node.plist` | Path to node plist |
| Poll Interval | `3` seconds | How often to check service status |

### Auto-detect

Click **Scan** in Preferences to automatically discover OpenClaw-related plists in `~/Library/LaunchAgents/`. Detected services can be applied with one click.

---

## Project Structure

```
OpenClawToggle/
├── Package.swift                          # SPM manifest (macOS 14+)
├── Info.plist                             # Bundle metadata (LSUIElement, versioning)
├── build-app.sh                           # Build script → .app bundle
├── Sources/OpenClawToggle/
│   ├── OpenClawToggleApp.swift            # Entry point, AppDelegate, NSStatusItem, MenuBarIcon
│   ├── StatusMonitor.swift                # ObservableObject — polling & shell commands
│   ├── PopoverView.swift                  # SwiftUI popover with service controls
│   ├── PreferencesView.swift              # Settings panel with auto-detect
│   ├── AboutView.swift                    # About window with version info
│   ├── AppSettings.swift                  # UserDefaults-backed configuration
│   └── ServiceDetector.swift              # Scans ~/Library/LaunchAgents for OpenClaw plists
├── Resources/
│   ├── alfred-icon.png                    # Menu bar avatar icon
│   └── AppIcon.icns                       # App icon for .app bundle
├── ROADMAP.md
├── README.md
├── LICENSE
└── .gitignore
```

---

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│  OpenClawToggleEntry (@main)                            │
│  └── AppDelegate (NSApplicationDelegate)                │
│      ├── NSStatusItem (menu bar icon)                   │
│      ├── NSMenu → PopoverView (SwiftUI via NSHostingView)│
│      ├── StatusMonitor (polling + launchctl)             │
│      ├── AppSettings.shared (UserDefaults)              │
│      ├── PreferencesView → ServiceDetector              │
│      └── AboutView (version, links)                     │
└─────────────────────────────────────────────────────────┘
```

---

## Contributing

Contributions are welcome! See the [ROADMAP.md](ROADMAP.md) for planned features.

1. Fork the repo
2. Create a feature branch
3. `swift build` to make sure it compiles
4. Submit a pull request

---

## License

This project is licensed under the [MIT License](LICENSE).
