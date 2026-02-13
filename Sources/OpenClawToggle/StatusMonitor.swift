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

    /// Tracks whether the launchd service is loaded (bootstrapped).
    /// When `false`, the service has been booted out and won't auto-restart.
    @Published private(set) var serviceLoaded: Bool = true

    // MARK: Configuration

    /// Local port used by the SSH tunnel.
    private let tunnelPort: UInt16 = 18789

    /// Launchd service label for the OpenClaw node.
    private let serviceLabel = "ai.openclaw.node"

    /// How often (in seconds) to refresh status.
    private let pollInterval: TimeInterval = 5

    /// The current user's UID (used in launchctl gui/<uid>/… paths).
    private let uid: String = {
        ProcessInfo.processInfo.environment["SUDO_UID"]
            ?? String(getuid())
    }()

    /// Path to the LaunchAgent plist.
    private var plistPath: String {
        NSHomeDirectory() + "/Library/LaunchAgents/\(serviceLabel).plist"
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

    // MARK: Toggle

    /// Start or stop the launchd node service.
    ///
    /// To **stop**: `launchctl bootout gui/<uid>/<label>` which unloads
    /// the service entirely so KeepAlive cannot restart it.
    ///
    /// To **start**: `launchctl bootstrap gui/<uid> <plist>` which
    /// re-loads the service and starts it due to RunAtLoad.
    func toggleNode() async {
        guard !isToggling else { return }
        isToggling = true
        defer { isToggling = false }

        if nodeRunning || serviceLoaded {
            // Bootout unloads the service so KeepAlive won't restart it.
            await runShell("/bin/launchctl", arguments: [
                "bootout", "gui/\(uid)/\(serviceLabel)"
            ])
            serviceLoaded = false
        } else {
            // Bootstrap re-loads the plist; RunAtLoad will start the process.
            await runShell("/bin/launchctl", arguments: [
                "bootstrap", "gui/\(uid)", plistPath
            ])
            serviceLoaded = true
        }

        // Brief pause so launchd has time to act, then refresh.
        try? await Task.sleep(for: .milliseconds(800))
        await refresh()
    }

    // MARK: - Private helpers

    /// Returns `true` when something is listening on `tunnelPort`.
    private func checkTunnel() async -> Bool {
        let output = await runShell(
            "/usr/sbin/lsof",
            arguments: ["-iTCP:\(tunnelPort)", "-sTCP:LISTEN", "-P", "-n"]
        )
        return !output.isEmpty
    }

    /// Returns `true` when the launchd service has a running PID.
    /// Also updates `serviceLoaded` based on whether the service exists.
    private func checkNode() async -> Bool {
        let output = await runShell(
            "/bin/launchctl", arguments: ["print", "gui/\(uid)/\(serviceLabel)"]
        )

        let lines = output.lowercased()

        // If launchctl can't find the service, it's been booted out.
        if lines.contains("could not find service") || output.isEmpty {
            serviceLoaded = false
            return false
        }

        // Service is loaded in launchd.
        serviceLoaded = true

        if lines.contains("state = running") { return true }

        // Check pid line as fallback.
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
