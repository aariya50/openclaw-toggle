# Roadmap

## v1.0 ✅
- Menu bar status indicator with service controls
- Preferences panel with auto-detect
- Homebrew formula and GitHub Releases
- CI/CD with GitHub Actions

## v2.0 ✅ — Setup Wizard & Improvements
- First-run setup wizard (5-step guided setup)
- SSH tunnel and node service configuration (gateway host, port, plist paths)
- Health diagnostics (plist existence, service status, port listening, SSH connectivity)
- Auto-update via Sparkle (GitHub Releases appcast)
- Launch at Login (SMAppService)

## v3.0 ✅ — Power Features & UI Polish
- ✅ Logs viewer (standalone window with unified log + launchd file fallback, source filtering)
- ✅ Quick restart actions for tunnel and node (popover restart buttons)
- ✅ Connection drop notifications (macOS native UNUserNotification on state transitions)
- ✅ Sparkle auto-restart after update (SUAutomaticallyUpdate + automatic downloads)
- ✅ Redesigned Preferences window (clean Form/Section layout, Sparkle-based updates)
- ✅ Redesigned About window (real app icon, proper layout, corrected links)
- ✅ Fixed popover refresh button (replaced non-functional spinner)
- Multi-node support (deferred to v4.0)
- Global keyboard shortcut (deferred to v4.0)

## v4.0 — Voice Assistant & Advanced Features
- Multi-node support (deferred from v3.0)
- Global keyboard shortcut (deferred from v3.0)
- Always-on voice listening (hot mic / push-to-talk)
- Speech-to-text via ElevenLabs API
- Send transcribed voice to Alfred via OpenClaw node
- Audio response playback (TTS)
