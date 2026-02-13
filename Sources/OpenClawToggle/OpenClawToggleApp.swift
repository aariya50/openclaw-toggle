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

    func applicationWillTerminate(_ notification: Notification) {
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
// MARK: - Menu Bar Icon
// ---------------------------------------------------------------------------

/// Creates a composited menu bar icon: alfred-icon.png resized to 18×18 with
/// a small colored status dot badge in the bottom-right corner.
enum MenuBarIcon {
    /// Standard menu bar icon size.
    static let size = NSSize(width: 18, height: 18)

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
            // Draw the base icon resized to 18×18
            if let base = baseIcon {
                base.draw(
                    in: rect,
                    from: NSRect(origin: .zero, size: base.size),
                    operation: .sourceOver,
                    fraction: 1.0
                )
            }

            // Draw a 6px colored status dot in the bottom-right corner
            let dotSize: CGFloat = 6
            let dotColor: NSColor = switch state {
            case .connected:    .systemGreen
            case .tunnelOnly:   .systemYellow
            case .disconnected: .systemRed
            }
            dotColor.setFill()
            let dotRect = NSRect(
                x: rect.width - dotSize,
                y: 0,
                width: dotSize,
                height: dotSize
            )
            let dot = NSBezierPath(ovalIn: dotRect)
            dot.fill()

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
