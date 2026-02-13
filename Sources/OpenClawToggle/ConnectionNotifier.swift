// SPDX-License-Identifier: MIT
// OpenClaw Toggle — macOS native notifications for connection drops.

import Foundation
import UserNotifications

// ---------------------------------------------------------------------------
// MARK: - Connection Notifier
// ---------------------------------------------------------------------------

/// Monitors `StatusMonitor` state transitions and posts macOS native
/// notifications when a service goes down (or recovers).
///
/// Usage: create once in AppDelegate, call `start(monitor:)` after polling
/// begins.  The notifier observes published state changes via Combine.
@MainActor
final class ConnectionNotifier: NSObject, ObservableObject {

    /// Whether drop notifications are enabled (user preference).
    @Published var isEnabled: Bool = true

    /// Track previous state so we only notify on *transitions*.
    private var previousState: ConnectionState?
    private var previousTunnelActive: Bool?
    private var previousNodeRunning: Bool?

    private var observation: Any?

    // MARK: - Setup

    /// Request notification permission and start observing state changes.
    func start(monitor: StatusMonitor) {
        requestPermission()

        // Observe the monitor's published properties using a Task that
        // watches for changes.  We use a simple polling approach here
        // since StatusMonitor is @MainActor and we can read its values.
        observation = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.evaluate(monitor: monitor)
            }
        }
    }

    func stop() {
        (observation as? Timer)?.invalidate()
        observation = nil
    }

    // MARK: - Permission

    private func requestPermission() {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                print("[ConnectionNotifier] Permission error: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - State evaluation

    private func evaluate(monitor: StatusMonitor) {
        guard isEnabled else {
            previousState = monitor.state
            previousTunnelActive = monitor.tunnelActive
            previousNodeRunning = monitor.nodeRunning
            return
        }

        let currentState = monitor.state
        let tunnelNow = monitor.tunnelActive
        let nodeNow = monitor.nodeRunning

        // Only fire on transitions (not on initial read)
        if let prevTunnel = previousTunnelActive, let prevNode = previousNodeRunning {

            // Tunnel went down
            if prevTunnel && !tunnelNow {
                postNotification(
                    title: "SSH Tunnel Disconnected",
                    body: "The SSH tunnel has stopped. Node service may also be affected.",
                    identifier: "tunnel-down"
                )
            }

            // Tunnel recovered
            if !prevTunnel && tunnelNow {
                postNotification(
                    title: "SSH Tunnel Connected",
                    body: "The SSH tunnel is back online.",
                    identifier: "tunnel-up"
                )
            }

            // Node went down (but tunnel still up — otherwise the tunnel
            // notification already covers it)
            if prevNode && !nodeNow && tunnelNow {
                postNotification(
                    title: "Node Service Stopped",
                    body: "The OpenClaw node service has stopped while the tunnel is still active.",
                    identifier: "node-down"
                )
            }

            // Node recovered
            if !prevNode && nodeNow {
                postNotification(
                    title: "Node Service Running",
                    body: "The OpenClaw node service is back online.",
                    identifier: "node-up"
                )
            }

            // Full stack went down
            if let prevState = previousState,
               prevState == .connected && currentState == .disconnected {
                postNotification(
                    title: "OpenClaw Disconnected",
                    body: "All services have stopped. Open the app to restart.",
                    identifier: "all-down"
                )
            }
        }

        previousState = currentState
        previousTunnelActive = tunnelNow
        previousNodeRunning = nodeNow
    }

    // MARK: - Post notification

    private func postNotification(title: String, body: String, identifier: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "ai.openclaw.toggle.\(identifier).\(UUID().uuidString)",
            content: content,
            trigger: nil // Deliver immediately
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                print("[ConnectionNotifier] Failed to post notification: \(error.localizedDescription)")
            }
        }
    }
}
