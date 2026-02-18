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
- Multi-node support (deferred to v5.0)
- Global keyboard shortcut (done in v4.0)

## v4.0 ✅ — Voice Assistant
- ✅ Global keyboard shortcut (Shift+Delete push-to-talk)
- ✅ Push-to-talk voice recording
- ✅ Speech-to-text via OpenAI Whisper
- ✅ Send transcribed voice to Alfred via OpenClaw agent CLI
- ✅ Audio response playback (OpenAI TTS, echo voice)
- ✅ Chat window (persistent Telegram-style UI)
- Multi-node support (deferred to v5.0)

## v5.0 — Planned
- Multi-node support
