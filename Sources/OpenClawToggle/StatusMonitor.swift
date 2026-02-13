// SPDX-License-Identifier: MIT
// OpenClaw Toggle — macOS menu bar app for OpenClaw node management.

import SwiftUI

// ---------------------------------------------------------------------------
// MARK: - Connection State
// ---------------------------------------------------------------------------

/// Represents the aggregate health of the OpenClaw stack.
enum ConnectionState: String {
    case connected    = "Connected"      // tunnel + node both running
    case tunnelOnly   = "Tunnel Only"    // tunnel alive, node stopped
    case disconnected = "Disconnected"   // neither running

    /// SF Symbol color shown in the menu bar and status dot.
    var color: Color {
        switch self {
        case .connected:    return .green
        case .tunnelOnly:   return .yellow
        case .disconnected: return .red
        }
    }
}

// ---------------------------------------------------------------------------
// MARK: - Status Monitor
// ---------------------------------------------------------------------------

/// Polls system state every few seconds and publishes the results so SwiftUI
/// views stay in sync automatically.
@MainActor
final class StatusMonitor: ObservableObject {

    // MARK: Published state

    @Published private(set) var tunnelActive: Bool = false
    @Published private(set) var nodeRunning: Bool  = false
    @Published private(set) var state: ConnectionState = .disconnected
    @Published private(set) var isToggling: Bool = false
    @Published private(set) var isTunnelToggling: Bool = false

    /// Whether the tunnel port is actively listening (lsof check).
    @Published private(set) var tunnelPortListening: Bool = false

    /// Tracks whether the launchd node service is loaded (bootstrapped).
    @Published private(set) var serviceLoaded: Bool = false

    /// Tracks whether the launchd tunnel service is loaded (bootstrapped).
    @Published private(set) var tunnelServiceLoaded: Bool = false

    // MARK: Configuration

    /// Local port used by the SSH tunnel.
    private let tunnelPort: UInt16 = 18789

    /// Launchd service label for the OpenClaw node.
    private let nodeServiceLabel = "ai.openclaw.node"

    /// Launchd service label for the SSH tunnel.
    private let tunnelServiceLabel = "ai.openclaw.ssh-tunnel"

    /// How often (in seconds) to refresh status.
    private let pollInterval: TimeInterval = 3

    /// The current user's UID (used in launchctl gui/<uid>/… paths).
    private let uid: String = {
        ProcessInfo.processInfo.environment["SUDO_UID"]
            ?? String(getuid())
    }()

    /// Path to the node LaunchAgent plist.
    private var nodePlistPath: String {
        NSHomeDirectory() + "/Library/LaunchAgents/\(nodeServiceLabel).plist"
    }

    /// Path to the tunnel LaunchAgent plist.
    private var tunnelPlistPath: String {
        NSHomeDirectory() + "/Library/LaunchAgents/\(tunnelServiceLabel).plist"
    }

    private var pollTask: Task<Void, Never>?

    // MARK: Lifecycle

    func startPolling() {
        stopPolling()
        pollTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.refresh()
                try? await Task.sleep(for: .seconds(self.pollInterval))
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    // MARK: Refresh

    /// Runs both checks concurrently, then derives the aggregate state.
    func refresh() async {
        async let tunnel = checkTunnel()
        async let node   = checkNode()

        let (t, n) = await (tunnel, node)
        tunnelActive = t
        nodeRunning  = n

        switch (t, n) {
        case (true, true):   state = .connected
        case (true, false):  state = .tunnelOnly
        default:             state = .disconnected
        }
    }

    // MARK: Toggle Node

    /// Start or stop the launchd node service.
    func toggleNode() async {
        guard !isToggling else { return }
        isToggling = true
        defer { isToggling = false }

        if nodeRunning || serviceLoaded {
            await runShell("/bin/launchctl", arguments: [
                "bootout", "gui/\(uid)/\(nodeServiceLabel)"
            ])
            serviceLoaded = false
        } else {
            await runShell("/bin/launchctl", arguments: [
                "bootstrap", "gui/\(uid)", nodePlistPath
            ])
            serviceLoaded = true
        }

        try? await Task.sleep(for: .milliseconds(800))
        await refresh()
    }

    // MARK: Toggle Tunnel

    /// Start or stop the launchd SSH tunnel service.
    /// NOTE: This method intentionally only touches the tunnel service
    /// (ai.openclaw.ssh-tunnel).  It must NOT bootstrap or bootout the
    /// node service — the user controls those independently.
    func toggleTunnel() async {
        guard !isTunnelToggling else { return }
        isTunnelToggling = true
        defer { isTunnelToggling = false }

        let wasStopping = tunnelActive || tunnelServiceLoaded

        if wasStopping {
            // Only bootout the tunnel — nothing else.
            await runShell("/bin/launchctl", arguments: [
                "bootout", "gui/\(uid)/\(tunnelServiceLabel)"
            ])
            tunnelServiceLoaded = false

            // The node cannot function without the tunnel, so reflect
            // the stopped state in the UI immediately — don't wait for
            // the next poll cycle.
            tunnelActive = false
            nodeRunning  = false
            state        = .disconnected
        } else {
            // Only bootstrap the tunnel plist — nothing else.
            await runShell("/bin/launchctl", arguments: [
                "bootstrap", "gui/\(uid)", tunnelPlistPath
            ])
            tunnelServiceLoaded = true
        }

        // Immediate refresh for quick visual feedback.
        try? await Task.sleep(for: .milliseconds(800))
        await refresh()

        // When stopping the tunnel, the node may take a moment to
        // notice the tunnel is gone.  Schedule follow-up refreshes
        // so the UI catches the node going down faster.
        if wasStopping {
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(2))
                await self?.refresh()
            }
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(5))
                await self?.refresh()
            }
        }
    }

    // MARK: - Private helpers

    /// Returns `true` when the tunnel service process is running (has a
    /// running state or valid PID in launchd).  Also updates
    /// `tunnelServiceLoaded` and `tunnelPortListening` as side-effects.
    private func checkTunnel() async -> Bool {
        // 1. Port check – is something actually listening on the tunnel port?
        let lsofOutput = await runShell(
            "/usr/sbin/lsof",
            arguments: ["-iTCP:\(tunnelPort)", "-sTCP:LISTEN", "-P", "-n"]
        )
        tunnelPortListening = !lsofOutput.isEmpty

        // 2. Service check – is the launchd service loaded & running?
        let svcOutput = await runShell(
            "/bin/launchctl",
            arguments: ["print", "gui/\(uid)/\(tunnelServiceLabel)"]
        )
        let lines = svcOutput.lowercased()

        if lines.contains("could not find service") || svcOutput.isEmpty {
            tunnelServiceLoaded = false
            return false
        }

        tunnelServiceLoaded = true

        // Check for running state
        if lines.contains("state = running") { return true }

        // Check for a valid PID
        if let range = lines.range(of: "pid = ") {
            let after = lines[range.upperBound...]
            let digits = after.prefix(while: { $0.isNumber })
            if let pid = Int(digits), pid > 0 { return true }
        }
        return false
    }

    /// Returns `true` when the launchd service has a running PID.
    /// Also updates `serviceLoaded` based on whether the service exists.
    private func checkNode() async -> Bool {
        let output = await runShell(
            "/bin/launchctl", arguments: ["print", "gui/\(uid)/\(nodeServiceLabel)"]
        )

        let lines = output.lowercased()

        if lines.contains("could not find service") || output.isEmpty {
            serviceLoaded = false
            return false
        }

        serviceLoaded = true

        if lines.contains("state = running") { return true }

        if let range = lines.range(of: "pid = ") {
            let after = lines[range.upperBound...]
            let digits = after.prefix(while: { $0.isNumber })
            if let pid = Int(digits), pid > 0 { return true }
        }
        return false
    }

    /// Runs a command and returns its trimmed stdout (ignoring failures).
    @discardableResult
    private func runShell(_ path: String, arguments: [String]) async -> String {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                let pipe = Pipe()
                process.executableURL = URL(fileURLWithPath: path)
                process.arguments = arguments
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice
                do {
                    try process.run()
                    process.waitUntilExit()
                } catch {
                    continuation.resume(returning: "")
                    return
                }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                continuation.resume(returning: output)
            }
        }
    }
}
