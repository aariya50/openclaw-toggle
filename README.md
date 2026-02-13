# OpenClaw Toggle

A lightweight, native macOS menu bar app that monitors and controls the [OpenClaw](https://openclaw.ai) node service.

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-blue)
![Swift 5.9](https://img.shields.io/badge/Swift-5.9-orange)
![License: MIT](https://img.shields.io/badge/License-MIT-green)

## What It Does

OpenClaw Toggle sits in your menu bar and gives you at-a-glance status of your OpenClaw stack:

| Icon Color | Meaning |
|------------|---------|
| 🟢 Green | SSH tunnel **and** node service are running |
| 🟡 Yellow | SSH tunnel active, but node service is stopped |
| 🔴 Red | Neither tunnel nor node is running |

Click the icon to see a popover with:

- **Status indicator** — colored dot + human-readable state
- **Tunnel status** — whether port `18789` is listening
- **Node status** — whether the `ai.openclaw.node` launchd service has an active PID
- **Start / Stop button** — toggles the node service via `launchctl`
- **Quit button**

Status is polled every 5 seconds automatically.

## Requirements

- macOS 14 (Sonoma) or later
- Swift 5.9+ / Xcode 15+
- An existing `ai.openclaw.node` launchd service (LaunchAgent plist)
- An SSH tunnel forwarding to local port `18789`

## Building

```bash
# Clone the repo
git clone https://github.com/your-org/OpenClawToggle.git
cd OpenClawToggle

# Build with Swift Package Manager
swift build

# Run the debug build
.build/debug/OpenClawToggle
```

### Release build

```bash
swift build -c release
# Binary at .build/release/OpenClawToggle
```

## How It Works

| Component | Detail |
|-----------|--------|
| **Tunnel check** | Runs `lsof -iTCP:18789 -sTCP:LISTEN` to see if anything is listening |
| **Node check** | Runs `launchctl print gui/<uid>/ai.openclaw.node` and parses for `state = running` or a live PID |
| **Start node** | `launchctl kickstart -k gui/<uid>/ai.openclaw.node` |
| **Stop node** | `launchctl kill SIGTERM gui/<uid>/ai.openclaw.node` |

The app hides from the Dock via `LSUIElement = true` in its Info.plist.

## Project Structure

```
OpenClawToggle/
├── Package.swift                          # SPM manifest (macOS 14+)
├── Sources/OpenClawToggle/
│   ├── OpenClawToggleApp.swift            # Entry point, AppDelegate, NSStatusItem
│   ├── StatusMonitor.swift                # ObservableObject — polling & shell commands
│   ├── PopoverView.swift                  # SwiftUI popover UI
│   └── Resources/
│       └── Info.plist                     # Bundle metadata (LSUIElement)
├── README.md
├── LICENSE
└── .gitignore
```

## Contributing

Contributions are welcome! Please open an issue or pull request.

## License

This project is licensed under the [MIT License](LICENSE).
