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

/// Owns the `NSStatusItem` and the popover.  Using an AppDelegate gives us
/// full control over the menu bar icon lifecycle and avoids the pitfalls of
/// MenuBarExtra (which has limited customisation on macOS 14).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {

    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private let monitor = StatusMonitor()
    private var cancellables = Set<AnyCancellable>()

    // MARK: NSApplicationDelegate

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide dock icon programmatically as a safety net
        // (Info.plist LSUIElement is the primary mechanism when bundled).
        NSApp.setActivationPolicy(.accessory)

        // ── Status bar item ───────────────────────────────────────────
        statusItem = NSStatusBar.system.statusItem(
            withLength: NSStatusItem.variableLength
        )
        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "circle.fill",
                accessibilityDescription: "OpenClaw status"
            )
            // Start with red (disconnected) tint.
            button.contentTintColor = .systemRed
            button.action = #selector(togglePopover(_:))
            button.target = self
        }

        // ── Popover ───────────────────────────────────────────────────
        let contentView = PopoverView(monitor: monitor)
        popover.contentViewController = NSHostingController(rootView: contentView)
        popover.behavior = .transient
        popover.delegate = self

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

    // MARK: Icon tint

    private func updateIcon(for state: ConnectionState) {
        let color: NSColor = switch state {
        case .connected:    .systemGreen
        case .tunnelOnly:   .systemYellow
        case .disconnected: .systemRed
        }
        statusItem.button?.contentTintColor = color
    }

    // MARK: Popover toggle

    @objc private func togglePopover(_ sender: Any?) {
        if popover.isShown {
            popover.performClose(sender)
        } else if let button = statusItem.button {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            // Bring our popover window to front.
            popover.contentViewController?.view.window?.makeKey()
        }
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
