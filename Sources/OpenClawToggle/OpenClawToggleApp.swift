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

/// Creates a composited menu bar icon: colored circle + 🎩 emoji.
enum MenuBarIcon {
    /// Standard menu bar icon size.
    static let size = NSSize(width: 18, height: 18)

    static func create(for state: ConnectionState) -> NSImage {
        let img = NSImage(size: size, flipped: false) { rect in
            // Draw colored circle background
            let bgColor: NSColor = switch state {
            case .connected:    .systemGreen
            case .tunnelOnly:   .systemYellow
            case .disconnected: .systemRed
            }
            bgColor.setFill()
            let circle = NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5))
            circle.fill()

            // Draw 🎩 emoji centered on top
            let emoji = "🎩" as NSString
            let fontSize: CGFloat = 12
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: fontSize),
            ]
            let emojiSize = emoji.size(withAttributes: attrs)
            let emojiRect = NSRect(
                x: (rect.width - emojiSize.width) / 2,
                y: (rect.height - emojiSize.height) / 2,
                width: emojiSize.width,
                height: emojiSize.height
            )
            emoji.draw(in: emojiRect, withAttributes: attrs)
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
