// SPDX-License-Identifier: MIT
// OpenClaw Toggle — main app entry point.
//
// A menu-bar-only macOS app that monitors and controls the OpenClaw node
// service.  No Dock icon is shown (controlled via NSApp.setActivationPolicy).

import AppKit
import Combine
import HotKey
import SwiftUI

// ---------------------------------------------------------------------------
// MARK: - App Delegate
// ---------------------------------------------------------------------------

/// Owns the `NSStatusItem` and the menu.  Uses NSMenu with a custom
/// NSMenuItem containing an NSHostingView instead of NSPopover, which
/// eliminates the common gap-below-menu-bar-icon issue on macOS.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private var statusItem: NSStatusItem!
    private let monitor = StatusMonitor()
    private let settings = AppSettings.shared
    private var cancellables = Set<AnyCancellable>()
    private lazy var lifecycle = ServiceLifecycleManager(settings: settings)

    /// Sparkle auto-updater manager — created once, lives for the app.
    private lazy var updater = SparkleUpdaterManager()

    /// Connection drop notifier — posts macOS notifications on state changes.
    private lazy var notifier = ConnectionNotifier()

    /// Voice assistant — push-to-talk + OpenAI pipeline.
    private lazy var voiceAssistant = VoiceAssistant(monitor: monitor, settings: settings)

    /// Floating overlay that shows voice assistant state (recording, transcribing, etc.).
    private lazy var voiceOverlay = VoiceOverlayController()

    /// Global hotkey for push-to-talk (Shift + Delete) — uses Carbon API, no permissions needed.
    private var pushToTalkHotKey: HotKey?

    /// The menu shown when the status item is clicked.
    private let menu = NSMenu()

    /// The hosting view inside the custom menu item.
    private var hostingView: NSHostingView<PopoverView>?

    /// Standalone Preferences window (created on demand).
    private var preferencesWindow: NSWindow?

    /// About window (created on demand).
    private var aboutWindow: NSWindow?

    /// Setup Wizard window (created on demand).
    private var wizardWindow: NSWindow?

    /// Logs window (created on demand).

    // MARK: NSApplicationDelegate

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide dock icon programmatically as a safety net
        // (Info.plist LSUIElement is the primary mechanism when bundled).
        NSApp.setActivationPolicy(.accessory)
        // Prevent macOS from automatically terminating this menu bar app
        ProcessInfo.processInfo.disableAutomaticTermination("Menu bar app must stay alive")
        ProcessInfo.processInfo.disableSuddenTermination()

        // ── Install a main menu with File > Close (Cmd+W) ────────────
        installMainMenu()

        // ── First-run: show Setup Wizard ──────────────────────────────
        if !settings.hasCompletedSetup {
            // Try auto-detect first
            let count = ServiceDetector.detectAndApply(to: settings)
            if count == 0 {
                // No services found — show the Setup Wizard.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    self?.openSetupWizard()
                }
            }
        }

        // ── Status bar item ───────────────────────────────────────────
        statusItem = NSStatusBar.system.statusItem(
            withLength: NSStatusItem.variableLength
        )
        if let button = statusItem.button {
            button.image = MenuBarIcon.create(for: .disconnected)
            button.image?.isTemplate = false
        }

        // ── Menu with custom view ─────────────────────────────────────
        let contentView = PopoverView(
            monitor: monitor,
            updater: updater,
            voiceEnabled: settings.voiceEnabled,
            onOpenPreferences: { [weak self] in
                self?.scheduleOpenPreferences()
            },
            onOpenAbout: { [weak self] in
                self?.scheduleOpenAbout()
            }
        )
        let hostingView = NSHostingView(rootView: contentView)
        // Let the hosting view determine its ideal size.
        hostingView.setFrameSize(hostingView.fittingSize)
        self.hostingView = hostingView

        let menuItem = NSMenuItem()
        menuItem.view = hostingView
        menu.addItem(menuItem)
        menu.delegate = self

        statusItem.menu = menu

        // ── React to state changes ────────────────────────────────────
        monitor.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.updateIcon(for: state)
            }
            .store(in: &cancellables)

        // ── Start polling ─────────────────────────────────────────────
        monitor.startPolling()

        // ── Connection drop notifications ─────────────────────────────
        notifier.start(monitor: monitor)

        // ── Bootstrap services & install crash watchdog ───────────────
        lifecycle.start()

        // ── Voice assistant ──────────────────────────────────────────
        if settings.voiceEnabled {
            Task { await voiceAssistant.start() }
            voiceOverlay.start(assistant: voiceAssistant)
        }

        // ── Global hotkey: Shift + Delete → push-to-talk ───────────
        installPushToTalkHotkey()

        // ── Debug: listen for distributed notifications ──────────────
        #if DEBUG
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("ai.openclaw.toggle.openPreferences"),
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.openPreferences()
            }
        }

        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("ai.openclaw.toggle.captureWindows"),
            object: nil, queue: .main
        ) { _ in
            Task { @MainActor in
                DebugCapture.captureAllWindows()
            }
        }
        #endif
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Stop polling immediately so no new refresh cycles interfere.
        monitor.stopPolling()
        notifier.stop()
        voiceOverlay.stop()
        voiceAssistant.stop()
        pushToTalkHotKey = nil

        // Delegate all teardown (bootout services, remove PID file,
        // unload watchdog) to the lifecycle manager.
        lifecycle.teardown {
            NSApplication.shared.reply(toApplicationShouldTerminate: true)
        }

        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Polling already stopped in applicationShouldTerminate, but
        // guard against direct termination paths just in case.
        monitor.stopPolling()
        notifier.stop()
    }

    // MARK: Main Menu (Cmd+W support)

    /// Installs a minimal main menu bar so that Cmd+W works to close
    /// the frontmost window (Preferences, About, Setup Wizard).
    private func installMainMenu() {
        let mainMenu = NSMenu()

        // Application menu (required by macOS)
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        let quitItem = NSMenuItem(
            title: "Quit OpenClaw Toggle",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        appMenu.addItem(quitItem)
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // Edit menu (⌘X, ⌘C, ⌘V, ⌘A, ⌘Z)
        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        editMenu.addItem(NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z"))
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        // File menu with Close (Cmd+W)
        let fileMenuItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        let closeItem = NSMenuItem(
            title: "Close Window",
            action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "w"
        )
        fileMenu.addItem(closeItem)
        fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)

        NSApp.mainMenu = mainMenu
    }

    // MARK: Push-to-Talk Hotkey

    /// Installs global push-to-talk hotkey: Shift + Delete.
    /// Uses Carbon RegisterEventHotKey via HotKey library — no permissions needed.
    /// Hold to record, release to send. Press while speaking to cancel.
    private func installPushToTalkHotkey() {
        let hotKey = HotKey(key: .delete, modifiers: [.shift])
        hotKey.keyDownHandler = { [weak self] in
            Task { @MainActor in self?.voiceAssistant.startRecording() }
        }
        hotKey.keyUpHandler = { [weak self] in
            Task { @MainActor in self?.voiceAssistant.stopRecordingKey() }
        }
        pushToTalkHotKey = hotKey
    }

    // MARK: NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        // Resize the hosting view each time the menu opens to pick up
        // any content size changes from SwiftUI.
        hostingView?.setFrameSize(hostingView?.fittingSize ?? .zero)
    }

    // MARK: Deferred open helpers (Bug #1 fix)

    /// Schedule opening Preferences after the menu finishes closing.
    /// This avoids the menu tracking loop conflict where clicking a
    /// button inside the menu's NSHostingView races with cancelTracking.
    private func scheduleOpenPreferences() {
        menu.cancelTracking()
        DispatchQueue.main.async { [weak self] in
            self?.openPreferences()
        }
    }

    /// Schedule opening About after the menu finishes closing.
    private func scheduleOpenAbout() {
        menu.cancelTracking()
        DispatchQueue.main.async { [weak self] in
            self?.openAbout()
        }
    }


    // MARK: Setup Wizard

    func openSetupWizard() {
        // Close the menu if it's open.
        menu.cancelTracking()

        if let existing = wizardWindow, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let wizardView = SetupWizardView(settings: settings) { [weak self] in
            // Wizard completed — close the window.
            self?.wizardWindow?.close()
        }
        let hostingController = NSHostingController(rootView: wizardView)
        let window = NSWindow(contentViewController: hostingController)
        window.title = "OpenClaw Toggle — Setup"
        window.styleMask = [.titled, .closable]
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        wizardWindow = window

        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            guard let strongSelf = self else { return }
            Task { @MainActor in
                strongSelf.wizardWindow = nil
                // Revert to accessory if no other windows are open
                if strongSelf.preferencesWindow?.isVisible != true
                    && strongSelf.aboutWindow?.isVisible != true {
                    NSApp.setActivationPolicy(.accessory)
                }
            }
        }
    }

    // MARK: Preferences Window

    func openPreferences() {
        if let existing = preferencesWindow, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let prefsView = PreferencesView(
            settings: settings,
            updater: updater,
            onApplyVoiceSettings: { [weak self] in
                guard let self else { return }
                if self.settings.voiceEnabled {
                    Task { await self.voiceAssistant.restart() }
                    self.voiceOverlay.start(assistant: self.voiceAssistant)
                } else {
                    self.voiceOverlay.stop()
                    self.voiceAssistant.stop()
                }
            }
        )
        let hostingController = NSHostingController(rootView: prefsView)
        let window = NSWindow(contentViewController: hostingController)
        window.title = "OpenClaw Toggle — Preferences"
        window.styleMask = [.titled, .closable]
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)

        // Temporarily become a regular app so the Preferences window can
        // receive focus and appear in the app switcher.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        preferencesWindow = window

        // When the window closes, go back to accessory (no Dock icon).
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            guard let strongSelf = self else { return }
            Task { @MainActor in
                strongSelf.preferencesWindow = nil
                if strongSelf.wizardWindow?.isVisible != true
                    && strongSelf.aboutWindow?.isVisible != true {
                    NSApp.setActivationPolicy(.accessory)
                }
            }
        }
    }

    // MARK: Icon update

    private func updateIcon(for state: ConnectionState) {
        statusItem.button?.image = MenuBarIcon.create(for: state)
        statusItem.button?.image?.isTemplate = false
    }

    // MARK: Logs Window


    // MARK: About Window

    func openAbout() {
        if let existing = aboutWindow, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let aboutView = AboutView()
        let hostingController = NSHostingController(rootView: aboutView)
        let window = NSWindow(contentViewController: hostingController)
        window.title = "About OpenClaw Toggle"
        window.styleMask = [.titled, .closable]
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        aboutWindow = window

        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            guard let strongSelf = self else { return }
            Task { @MainActor in
                strongSelf.aboutWindow = nil
                // Only revert to accessory if no other windows are open
                if strongSelf.preferencesWindow?.isVisible != true
                    && strongSelf.wizardWindow?.isVisible != true {
                    NSApp.setActivationPolicy(.accessory)
                }
            }
        }
    }
}

// ---------------------------------------------------------------------------
// MARK: - Menu Bar Icon (Instagram Close Friends style)
// ---------------------------------------------------------------------------

/// Creates a composited menu bar icon: alfred-icon.png clipped to a circle
/// with an Instagram Close Friends style ring around it.
///
/// - Connected (tunnel + node): bright green ring
/// - Tunnel Only: yellow ring
/// - Disconnected: no ring, avatar slightly dimmed
enum MenuBarIcon {
    /// Total canvas size for the menu bar icon.
    static let size = NSSize(width: 22, height: 22)

    /// Cached base icon loaded once from disk.
    private static let baseIcon: NSImage? = {
        // Try the app bundle first (works when running as OpenClawToggle.app)
        let bundlePath = Bundle.main.bundlePath
            + "/Contents/Resources/alfred-icon.png"
        if let img = NSImage(contentsOfFile: bundlePath) {
            return img
        }
        // Fallback: load from the source tree directly
        let fallbackPath = NSString(
            string: "~/Projects/OpenClawToggle/Resources/alfred-icon.png"
        ).expandingTildeInPath
        return NSImage(contentsOfFile: fallbackPath)
    }()

    static func create(for state: ConnectionState) -> NSImage {
        let img = NSImage(size: size, flipped: false) { rect in

            let center = NSPoint(x: rect.midX, y: rect.midY)

            // Layout constants
            let ringLineWidth: CGFloat = 2.0
            let gapWidth: CGFloat = 1.5
            let ringOuterRadius: CGFloat = min(rect.width, rect.height) / 2.0
            let ringCenterRadius = ringOuterRadius - ringLineWidth / 2.0
            let avatarRadius = ringOuterRadius - ringLineWidth - gapWidth

            // ── Draw ring (if not disconnected) ──────────────────────
            if state != .disconnected {
                let ringColor: NSColor = switch state {
                case .connected:  .systemGreen
                case .tunnelOnly: .systemYellow
                case .disconnected: .clear  // won't reach
                }
                ringColor.setStroke()
                let ringPath = NSBezierPath()
                ringPath.appendArc(
                    withCenter: center,
                    radius: ringCenterRadius,
                    startAngle: 0,
                    endAngle: 360
                )
                ringPath.lineWidth = ringLineWidth
                ringPath.stroke()
            }

            // ── Clip & draw circular avatar ──────────────────────────
            let avatarDiameter = avatarRadius * 2
            let avatarRect = NSRect(
                x: center.x - avatarRadius,
                y: center.y - avatarRadius,
                width: avatarDiameter,
                height: avatarDiameter
            )

            if let base = baseIcon {
                NSGraphicsContext.saveGraphicsState()
                let clipPath = NSBezierPath(ovalIn: avatarRect)
                clipPath.addClip()
                base.draw(
                    in: avatarRect,
                    from: NSRect(origin: .zero, size: base.size),
                    operation: .sourceOver,
                    fraction: state == .disconnected ? 0.45 : 1.0
                )
                NSGraphicsContext.restoreGraphicsState()
            }

            return true
        }
        img.isTemplate = false
        return img
    }
}

// ---------------------------------------------------------------------------
// MARK: - Entry point
// ---------------------------------------------------------------------------

/// Minimal `@main` struct to bootstrap the NSApplication run loop.
/// We use this instead of bare top-level code because SPM executable targets
/// with multiple source files don't allow top-level expressions.
@main
struct OpenClawToggleEntry {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}

// ---------------------------------------------------------------------------
// MARK: - Debug Window Capture
// ---------------------------------------------------------------------------

#if DEBUG
/// Captures all app windows to /tmp for visual debugging.
@MainActor
enum DebugCapture {
    static func captureAllWindows() {
        for window in NSApp.windows where window.isVisible {
            let title = window.title.isEmpty ? "untitled" : window.title
                .replacingOccurrences(of: " ", with: "-")
                .lowercased()
            guard let view = window.contentView else { continue }

            let bitmapRep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
            guard let rep = bitmapRep else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)

            guard let png = rep.representation(using: .png, properties: [:]) else { continue }
            let path = "/tmp/openclaw-\(title).png"
            try? png.write(to: URL(fileURLWithPath: path))
            print("[DebugCapture] Saved \(path) (\(rep.pixelsWide)x\(rep.pixelsHigh))")
        }
    }
}
#endif
