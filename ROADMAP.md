# OpenClaw Toggle — Roadmap

## v0.1 — MVP (Current)
- [x] Menu bar icon with connection status (green/yellow/red)
- [x] Popover with tunnel + node status
- [x] Start/Stop node toggle
- [x] 5-second polling
- [x] Swift Package Manager build
- [ ] Custom Alfred icon with colored glow
- [ ] Fix popover positioning (gap below icon)
- [ ] Proper stop behavior (bootout/bootstrap instead of kill)

## v1.0 — Public Release
- [ ] **Preferences panel** — configurable port, service labels, plist paths
- [ ] **Auto-detect** — scan for existing OpenClaw launchd services
- [ ] **Proper .app bundle** — with icon, versioning, About window
- [ ] **DMG installer** — drag-to-Applications distribution
- [ ] **Code signing + notarization** — Apple Developer certificate
- [ ] **README** — installation guide, screenshots, requirements
- [ ] **Homebrew cask** — `brew install --cask openclaw-toggle`
- [ ] **Launch at login** — optional auto-start on login
- [ ] **Menu bar icon options** — choice of icon style

## v2.0 — Setup Wizard
- [ ] **First-run wizard** — detect if OpenClaw is installed, guide setup
- [ ] **SSH tunnel setup** — help configure the tunnel + launchd plist
- [ ] **Node setup** — create/configure the node launchd service
- [ ] **Health diagnostics** — troubleshoot connection issues from the app
- [ ] **Auto-update** — Sparkle framework for in-app updates

## v3.0 — Power Features
- [ ] **Logs viewer** — view node/tunnel logs from the popover
- [ ] **Quick actions** — restart tunnel, restart node, view gateway URL
- [ ] **Notifications** — alert when connection drops/recovers
- [ ] **Multi-node support** — monitor multiple OpenClaw nodes
- [ ] **Keyboard shortcut** — global hotkey to toggle node

---

*Contributions welcome! See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.*
