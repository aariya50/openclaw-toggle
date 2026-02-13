// SPDX-License-Identifier: MIT
// OpenClaw Toggle — main app entry point.
//
// A menu-bar-only macOS app that monitors and controls the OpenClaw node
// service.  No Dock icon is shown (controlled via NSApp.setActivationPolicy).

import AppKit
import Combine
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
    private var cancellables = Set<AnyCancellable>()

    /// The menu shown when the status item is clicked.
    private let menu = NSMenu()

    /// The hosting view inside the custom menu item.
    private var hostingView: NSHostingView<PopoverView>?

    // MARK: NSApplicationDelegate

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide dock icon programmatically as a safety net
        // (Info.plist LSUIElement is the primary mechanism when bundled).
        NSApp.setActivationPolicy(.accessory)
        // Prevent macOS from automatically terminating this menu bar app
        ProcessInfo.processInfo.disableAutomaticTermination("Menu bar app must stay alive")
        ProcessInfo.processInfo.disableSuddenTermination()

        // ── Status bar item ───────────────────────────────────────────
        statusItem = NSStatusBar.system.statusItem(
            withLength: NSStatusItem.variableLength
        )
        if let button = statusItem.button {
            button.image = MenuBarIcon.create(for: .disconnected)
            button.image?.isTemplate = false
        }

        // ── Menu with custom view ─────────────────────────────────────
        let contentView = PopoverView(monitor: monitor)
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
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Stop polling immediately so no new refresh cycles interfere.
        monitor.stopPolling()

        // Bootout both launchd services before the app exits.
        // We return .terminateLater and call reply(.terminateNow) once
        // the bootout commands have finished.
        let uid = String(getuid())
        let labels = ["ai.openclaw.ssh-tunnel", "ai.openclaw.node"]

        Task.detached(priority: .userInitiated) {
            for label in labels {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
                process.arguments = ["bootout", "gui/\(uid)/\(label)"]
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                try? process.run()
                process.waitUntilExit()
            }
            await MainActor.run {
                NSApplication.shared.reply(toApplicationShouldTerminate: true)
            }
        }

        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Polling already stopped in applicationShouldTerminate, but
        // guard against direct termination paths just in case.
        monitor.stopPolling()
    }

    // MARK: NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        // Resize the hosting view each time the menu opens to pick up
        // any content size changes from SwiftUI.
        hostingView?.setFrameSize(hostingView?.fittingSize ?? .zero)
    }

    // MARK: Icon update

    private func updateIcon(for state: ConnectionState) {
        statusItem.button?.image = MenuBarIcon.create(for: state)
        statusItem.button?.image?.isTemplate = false
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
